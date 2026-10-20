/*
 * C consumer of the Bleu C ABI. Built with gcc -std=c11 -Wall -Wextra -pedantic, linked
 * against libbleu_capi, and run by tools/capi/tests/run.sh with a fake sysfs tree:
 *
 *   capi_smoke <root>
 *
 * <root> must contain sys/class/power_supply/{AC,BAT0} and sys/class/backlight/intel_backlight;
 * this program writes the files it changes. Exit status is the number of failed checks.
 */
#define _POSIX_C_SOURCE 200809L
#include <bleu/bleu.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
            failures++;                                                          \
        }                                                                        \
    } while (0)

static const char *g_root;

static void path_of(char *buffer, size_t size, const char *rel)
{
    snprintf(buffer, size, "%s/%s", g_root, rel);
}

static void write_file(const char *rel, const char *text)
{
    char path[1024];
    path_of(path, sizeof path, rel);
    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "cannot write %s\n", path);
        exit(2);
    }
    fputs(text, f);
    fclose(f);
}

static void read_file(const char *rel, char *buffer, size_t size)
{
    char path[1024];
    path_of(path, sizeof path, rel);
    FILE *f = fopen(path, "r");
    buffer[0] = 0;
    if (!f) return;
    if (!fgets(buffer, (int)size, f)) buffer[0] = 0;
    fclose(f);
    buffer[strcspn(buffer, "\n")] = 0;
}

static bool slice_equals(bleu_slice_t slice, const char *text)
{
    size_t n = strlen(text);
    return slice.len == n && memcmp(slice.ptr, text, n) == 0;
}

/* ---- battery: state, waiting, JSON ---------------------------------------- */

static void battery_state_through_the_struct(bleu_battery_t *battery)
{
    bleu_snapshot_t *snapshot = NULL;
    CHECK(bleu_battery_wait(battery, 0, 3000, &snapshot) == BLEU_STATUS_OK);
    CHECK(snapshot != NULL);
    const bleu_battery_state_t *state = bleu_battery_snapshot_state(snapshot);
    CHECK(state != NULL);
    CHECK(state->on_mains);                       /* AC is online in the fake tree */
    CHECK(state->sources.len == 2);
    CHECK(bleu_battery_source_at(state, 2) == NULL);          /* out of range is NULL, not a crash */
    const bleu_battery_source_t *bat = bleu_battery_source_at((bleu_battery_state_t *)state, 1);
    CHECK(bat != NULL);
    if (bat) {
        CHECK(slice_equals(bat->id, "BAT0"));
        CHECK(bat->kind == BLEU_BATTERY_KIND_BATTERY);
        CHECK(bat->state == BLEU_BATTERY_CHARGE_STATE_CHARGING);
        CHECK(bat->charge.has_value);
        CHECK(bat->charge.value > 0.49f && bat->charge.value < 0.51f);
        CHECK(bat->cycles.has_value && bat->cycles.value == 212);
        CHECK(slice_equals(bat->vendor, "ACME"));
        CHECK(bat->chemistry == BLEU_BATTERY_CHEMISTRY_LITHIUM_ION);
        CHECK(bat->health.has_value && bat->health.value > 0.79f && bat->health.value < 0.81f);
    }

    uint64_t generation = 0;
    CHECK(bleu_snapshot_generation(snapshot, &generation) == BLEU_STATUS_OK);
    CHECK(generation >= 1);

    /* A view of the same snapshot survives a retain and release of its own. */
    bleu_snapshot_t *kept = NULL;
    CHECK(bleu_snapshot_retain(snapshot, &kept) == BLEU_STATUS_OK);
    bleu_snapshot_release(snapshot);
    CHECK(bleu_battery_snapshot_state(kept) != NULL);
    bleu_snapshot_release(kept);
}

static void battery_json_and_backend(bleu_battery_t *battery)
{
    char *text = NULL;
    size_t length = 0;
    CHECK(bleu_battery_snapshot_json(battery, &text, &length) == BLEU_STATUS_OK);
    CHECK(text != NULL && length > 2 && text[0] == '{' && strstr(text, "\"on_mains\":true") != NULL);
    CHECK(text[length] == 0);
    bleu_free(text);

    char *name = NULL;
    size_t name_length = 0;
    CHECK(bleu_battery_backend_name(battery, &name, &name_length) == BLEU_STATUS_OK);
    CHECK(name != NULL && strcmp(name, "sysfs") == 0 && name_length == 5);
    bleu_free(name);

    bleu_capability_t capability;
    CHECK(bleu_battery_capability(battery, BLEU_BATTERY_CAP_CHARGE, &capability) == BLEU_STATUS_OK);
    CHECK(capability.reason == BLEU_AVAILABILITY_REASON_AVAILABLE);
    CHECK(bleu_battery_capability(battery, BLEU_BATTERY_CAP_TEMPERATURE, &capability) == BLEU_STATUS_OK);
}

/* ---- watch: a listener on the worker thread ---------------------------- */

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    int seen_mains;
    int calls;
    int reentry_status;
    bleu_battery_t *battery;
    uint64_t id;
} watch_state;

static void on_battery(void *context, const bleu_snapshot_t *snapshot)
{
    watch_state *state = (watch_state *)context;
    const bleu_battery_state_t *value = bleu_battery_snapshot_state((bleu_snapshot_t *)snapshot);
    pthread_mutex_lock(&state->mutex);
    state->calls++;
    if (value && value->on_mains) state->seen_mains = 1;
    /* A listener must not call into its own service: the call is refused, not deadlocked. */
    if (state->id != 0 && state->reentry_status == 0) {
        state->reentry_status = (int)bleu_battery_unwatch(state->battery, state->id);
    }
    pthread_cond_broadcast(&state->changed);
    pthread_mutex_unlock(&state->mutex);
}

static void battery_watch_from_another_thread(bleu_battery_t *battery)
{
    watch_state state;
    memset(&state, 0, sizeof state);
    pthread_mutex_init(&state.mutex, NULL);
    pthread_cond_init(&state.changed, NULL);
    state.battery = battery;

    /* Start unplugged, let the poll see it, then listen; plugging in must reach the listener. */
    write_file("sys/class/power_supply/AC/online", "0\n");
    struct timespec pause = { 0, 300 * 1000 * 1000 };
    nanosleep(&pause, NULL);

    uint64_t id = 0;
    CHECK(bleu_battery_watch(battery, on_battery, &state, &id) == BLEU_STATUS_OK);
    CHECK(id != 0);
    pthread_mutex_lock(&state.mutex);
    state.id = id;
    pthread_mutex_unlock(&state.mutex);

    write_file("sys/class/power_supply/AC/online", "1\n");

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    pthread_mutex_lock(&state.mutex);
    while (!state.seen_mains) {
        if (pthread_cond_timedwait(&state.changed, &state.mutex, &deadline) != 0) break;
    }
    int seen = state.seen_mains;
    int reentry = state.reentry_status;
    pthread_mutex_unlock(&state.mutex);
    CHECK(seen == 1);
    CHECK(reentry == BLEU_STATUS_INVALID_STATE);

    CHECK(bleu_battery_unwatch(battery, id) == BLEU_STATUS_OK);
    CHECK(bleu_battery_unwatch(battery, id) == BLEU_STATUS_NOT_FOUND);
    pthread_cond_destroy(&state.changed);
    pthread_mutex_destroy(&state.mutex);
}

/* ---- events: a reader and packets -------------------------------------- */

static void battery_events(bleu_battery_t *battery)
{
    bleu_reader_t *reader = NULL;
    CHECK(bleu_battery_subscribe(battery, &reader) == BLEU_STATUS_OK);
    CHECK(reader != NULL);

    CHECK(bleu_reader_next(reader, 0, NULL) == BLEU_STATUS_INVALID_ARGUMENT);
    bleu_packet_t *packet = NULL;
    CHECK(bleu_reader_next(reader, 20, &packet) == BLEU_STATUS_TIMEOUT);
    CHECK(packet == NULL);

    write_file("sys/class/power_supply/BAT0/status", "Discharging\n");
    bleu_status_t status = bleu_reader_next(reader, 3000, &packet);
    CHECK(status == BLEU_STATUS_OK);
    if (status == BLEU_STATUS_OK && packet) {
        const bleu_battery_event_t *event = bleu_battery_packet_event(packet);
        CHECK(event != NULL);
        if (event) CHECK(event->source_id.len > 0);
        bleu_packet_release(packet);
    }
    uint64_t dropped = 99;
    CHECK(bleu_reader_take_dropped(reader, &dropped) == BLEU_STATUS_OK);
    CHECK(dropped == 0);
    bleu_reader_release(reader);
}

/* ---- threads: any thread may call in ----------------------------------- */

static void *foreign_caller(void *argument)
{
    bleu_battery_t *battery = (bleu_battery_t *)argument;
    bleu_snapshot_t *snapshot = NULL;
    int ok = bleu_battery_snapshot(battery, &snapshot) == BLEU_STATUS_OK && snapshot != NULL;
    if (ok) bleu_snapshot_release(snapshot);
    char *text = NULL;
    size_t length = 0;
    ok = ok && bleu_battery_snapshot_json(battery, &text, &length) == BLEU_STATUS_OK;
    bleu_free(text);
    return (void *)(intptr_t)ok;
}

static void battery_from_a_pthread(bleu_battery_t *battery)
{
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, foreign_caller, battery) == 0);
    void *result = NULL;
    CHECK(pthread_join(thread, &result) == 0);
    CHECK((intptr_t)result == 1);
}

/* ---- brightness: operations, cancel, errors ---------------------------- */

static void brightness_set_and_read_back(bleu_brightness_t *brightness)
{
    bleu_brightness_set_request_t request;
    memset(&request, 0, sizeof request);
    request.struct_size = (uint32_t)sizeof request;
    request.device = "intel_backlight";
    request.level = 0.25f;

    bleu_operation_t *operation = NULL;
    CHECK(bleu_brightness_set_level(brightness, &request, &operation) == BLEU_STATUS_OK);
    CHECK(operation != NULL);
    CHECK(bleu_operation_wait(operation, 5000) == BLEU_STATUS_OK);

    bleu_operation_phase_t phase = BLEU_OPERATION_PHASE_PENDING;
    CHECK(bleu_operation_phase(operation, &phase) == BLEU_STATUS_OK);
    CHECK(phase == BLEU_OPERATION_PHASE_SUCCEEDED);
    const bleu_brightness_applied_t *applied = bleu_brightness_set_result(operation);
    CHECK(applied != NULL);
    if (applied) {
        CHECK(applied->raw == 24000);
        CHECK(applied->applied > 0.24f && applied->applied < 0.26f);
    }
    bleu_operation_release(operation);

    char value[64];
    read_file("sys/class/backlight/intel_backlight/brightness", value, sizeof value);
    CHECK(strcmp(value, "24000") == 0);
}

static void brightness_cancel_a_ramp(bleu_brightness_t *brightness)
{
    bleu_brightness_set_request_t request;
    memset(&request, 0, sizeof request);
    request.struct_size = (uint32_t)sizeof request;
    request.device = "intel_backlight";
    request.level = 1.0f;
    request.transition_ms = 5000;

    bleu_operation_t *operation = NULL;
    CHECK(bleu_brightness_set_level(brightness, &request, &operation) == BLEU_STATUS_OK);
    struct timespec pause = { 0, 150 * 1000 * 1000 };
    nanosleep(&pause, NULL);
    CHECK(bleu_operation_cancel(operation) == BLEU_STATUS_OK);
    CHECK(bleu_operation_wait(operation, 5000) == BLEU_STATUS_CANCELLED);
    bleu_operation_phase_t phase = BLEU_OPERATION_PHASE_PENDING;
    CHECK(bleu_operation_phase(operation, &phase) == BLEU_STATUS_OK);
    CHECK(phase == BLEU_OPERATION_PHASE_CANCELLED);
    CHECK(bleu_brightness_set_result(operation) == NULL);
    bleu_operation_release(operation);
}

static void brightness_failed_operation_has_details(bleu_brightness_t *brightness)
{
    bleu_brightness_set_request_t request;
    memset(&request, 0, sizeof request);
    request.struct_size = (uint32_t)sizeof request;
    request.device = "no-such-device";
    request.level = 0.5f;

    bleu_operation_t *operation = NULL;
    bleu_status_t refused = bleu_brightness_set_level(brightness, &request, &operation);
    if (refused == BLEU_STATUS_OK) {
        CHECK(bleu_operation_wait(operation, 5000) != BLEU_STATUS_OK);
        bleu_error_detail_t detail;
        CHECK(bleu_operation_detail(operation, &detail) == BLEU_STATUS_OK);
        CHECK(detail.status != BLEU_STATUS_OK);
        CHECK(detail.message[0] != 0);
        bleu_operation_release(operation);
    } else {
        bleu_error_detail_t detail;
        CHECK(bleu_last_error(&detail) == BLEU_STATUS_OK);
        CHECK(detail.status == refused);
        CHECK(detail.message[0] != 0);
    }
}

static void brightness_state_and_json(bleu_brightness_t *brightness)
{
    bleu_snapshot_t *snapshot = NULL;
    CHECK(bleu_brightness_wait(brightness, 0, 3000, &snapshot) == BLEU_STATUS_OK);
    const bleu_brightness_state_t *state = bleu_brightness_snapshot_state(snapshot);
    CHECK(state != NULL);
    if (state) {
        const bleu_brightness_device_t *device = bleu_brightness_device_at((bleu_brightness_state_t *)state, 0);
        CHECK(device != NULL);
        if (device) CHECK(slice_equals(device->id, "intel_backlight"));
        CHECK(bleu_brightness_device_at((bleu_brightness_state_t *)state, 99) == NULL);
    }
    bleu_snapshot_release(snapshot);

    char *text = NULL;
    size_t length = 0;
    CHECK(bleu_brightness_snapshot_json(brightness, &text, &length) == BLEU_STATUS_OK);
    CHECK(text != NULL && strstr(text, "intel_backlight") != NULL);
    bleu_free(text);
}

/* ---- errors -------------------------------------------------------------- */

static void open_errors(void)
{
    bleu_battery_options_t options;
    memset(&options, 0, sizeof options);

    bleu_battery_t *battery = NULL;
    options.struct_size = 0;
    CHECK(bleu_battery_open(&options, &battery) == BLEU_STATUS_INVALID_ARGUMENT);
    CHECK(battery == NULL);
    bleu_error_detail_t detail;
    CHECK(bleu_last_error(&detail) == BLEU_STATUS_OK);
    CHECK(detail.status == BLEU_STATUS_INVALID_ARGUMENT);
    CHECK(strstr(detail.message, "struct_size") != NULL);

    options.struct_size = (uint32_t)sizeof options;
    options.poll_ms = 1ull << 40;
    CHECK(bleu_battery_open(&options, &battery) == BLEU_STATUS_INVALID_ARGUMENT);
    CHECK(bleu_last_error(&detail) == BLEU_STATUS_OK && strstr(detail.message, "poll_ms") != NULL);

    options.poll_ms = 0;
    options.backend = BLEU_BATTERY_BACKEND_WIN32;
    CHECK(bleu_battery_open(&options, &battery) == BLEU_STATUS_UNSUPPORTED);
    CHECK(battery == NULL);

    CHECK(bleu_battery_open(&options, NULL) == BLEU_STATUS_INVALID_ARGUMENT);
    CHECK(strcmp(bleu_status_name(BLEU_STATUS_NOT_FOUND), "NOT_FOUND") == 0);
    CHECK(strcmp(bleu_status_name(12345), "INVALID") == 0);
    bleu_free(NULL);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <fake-root>\n", argv[0]);
        return 2;
    }
    g_root = argv[1];
    CHECK(bleu_abi_version() == BLEU_ABI_VERSION);

    open_errors();

    bleu_battery_options_t battery_options;
    memset(&battery_options, 0, sizeof battery_options);
    battery_options.struct_size = (uint32_t)sizeof battery_options;
    battery_options.backend = BLEU_BATTERY_BACKEND_SYSFS;
    battery_options.poll_ms = 50;
    battery_options.root = g_root;
    bleu_battery_t *battery = NULL;
    CHECK(bleu_battery_open(&battery_options, &battery) == BLEU_STATUS_OK);
    if (battery) {
        battery_state_through_the_struct(battery);
        battery_json_and_backend(battery);
        battery_watch_from_another_thread(battery);
        battery_events(battery);
        battery_from_a_pthread(battery);

        bleu_reader_t *reader = NULL;
        CHECK(bleu_battery_subscribe(battery, &reader) == BLEU_STATUS_OK);
        CHECK(bleu_battery_close(battery) == BLEU_STATUS_INVALID_STATE);  /* a reader is still open */
        bleu_reader_release(reader);
        CHECK(bleu_battery_close(battery) == BLEU_STATUS_OK);
    }

    bleu_brightness_options_t brightness_options;
    memset(&brightness_options, 0, sizeof brightness_options);
    brightness_options.struct_size = (uint32_t)sizeof brightness_options;
    brightness_options.backend = BLEU_BRIGHTNESS_BACKEND_LINUX;
    brightness_options.poll_ms = 100;
    brightness_options.transition_step_ms = 50;
    brightness_options.root = g_root;
    bleu_brightness_t *brightness = NULL;
    CHECK(bleu_brightness_open(&brightness_options, &brightness) == BLEU_STATUS_OK);
    if (brightness) {
        bleu_capability_t capability;
        CHECK(bleu_brightness_capability(brightness, BLEU_BRIGHTNESS_CAP_SET_BACKLIGHT, &capability) == BLEU_STATUS_OK);
        CHECK(capability.reason == BLEU_AVAILABILITY_REASON_AVAILABLE);
        brightness_state_and_json(brightness);
        brightness_set_and_read_back(brightness);
        brightness_cancel_a_ramp(brightness);
        brightness_failed_operation_has_details(brightness);
        CHECK(bleu_brightness_close(brightness) == BLEU_STATUS_OK);
    }

    if (failures == 0) printf("capi_smoke: all checks passed\n");
    else printf("capi_smoke: %d check(s) failed\n", failures);
    return failures;
}
