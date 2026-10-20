// C++ consumer of the Bleu C ABI: the same header, compiled as C++17 with -Wall -Wextra -pedantic -Werror.
#include <bleu/bleu.h>
#include <bleu/battery.h>
#include <bleu/brightness.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <chrono>

namespace {

int failures = 0;

#define CHECK(cond)                                                    \
    do {                                                               \
        if (!(cond)) {                                                 \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            ++failures;                                                \
        }                                                              \
    } while (0)

// Owns a handle-like pointer and releases it through the matching function.
template <typename T, void (*Release)(T *)>
struct Owned {
    T *ptr = nullptr;
    ~Owned() { if (ptr) Release(ptr); }
};

void release_snapshot(bleu_snapshot_t *s) { bleu_snapshot_release(s); }
void release_operation(bleu_operation_t *o) { bleu_operation_release(o); }

std::string take_text(char *text, size_t length) {
    std::string copy(text, length);
    bleu_free(text);
    return copy;
}

void write_file(const std::string &path, const char *text) {
    if (FILE *f = std::fopen(path.c_str(), "w")) {
        std::fputs(text, f);
        std::fclose(f);
    }
}

void battery_checks(const std::string &root) {
    bleu_battery_options_t options{};
    options.struct_size = sizeof options;
    options.backend = BLEU_BATTERY_BACKEND_SYSFS;
    options.poll_ms = 50;
    options.root = root.c_str();

    bleu_battery_t *battery = nullptr;
    CHECK(bleu_battery_open(&options, &battery) == BLEU_STATUS_OK);
    if (!battery) return;

    Owned<bleu_snapshot_t, release_snapshot> snapshot;
    CHECK(bleu_battery_wait(battery, 0, 3000, &snapshot.ptr) == BLEU_STATUS_OK);
    const bleu_battery_state_t *state = bleu_battery_snapshot_state(snapshot.ptr);
    CHECK(state != nullptr && state->on_mains);
    if (state) {
        const bleu_battery_source_t *source = bleu_battery_source_at(state, 1);
        CHECK(source != nullptr && source->kind == BLEU_BATTERY_KIND_BATTERY);
        CHECK(bleu_battery_source_at(state, 9) == nullptr);
    }

    // A C++ lambda without captures is a plain function pointer: usable as the listener.
    struct Counter { int calls = 0; } counter;
    uint64_t watch = 0;
    auto listener = [](void *context, const bleu_snapshot_t *) {
        static_cast<Counter *>(context)->calls++;
    };
    CHECK(bleu_battery_watch(battery, listener, &counter, &watch) == BLEU_STATUS_OK);
    CHECK(counter.calls >= 1);  // the current state is delivered at registration
    CHECK(bleu_battery_unwatch(battery, watch) == BLEU_STATUS_OK);

    char *json = nullptr;
    size_t length = 0;
    CHECK(bleu_battery_snapshot_json(battery, &json, &length) == BLEU_STATUS_OK);
    CHECK(json != nullptr && take_text(json, length).find("\"sources\"") != std::string::npos);

    CHECK(bleu_battery_close(battery) == BLEU_STATUS_OK);
}

void brightness_checks(const std::string &root) {
    bleu_brightness_options_t options{};
    options.struct_size = sizeof options;
    options.backend = BLEU_BRIGHTNESS_BACKEND_LINUX;
    options.root = root.c_str();
    options.poll_ms = 100;

    bleu_brightness_t *brightness = nullptr;
    CHECK(bleu_brightness_open(&options, &brightness) == BLEU_STATUS_OK);
    if (!brightness) return;

    bleu_brightness_set_request_t request{};
    request.struct_size = sizeof request;
    request.device = "intel_backlight";
    request.level = 0.5f;
    Owned<bleu_operation_t, release_operation> operation;
    CHECK(bleu_brightness_set_level(brightness, &request, &operation.ptr) == BLEU_STATUS_OK);
    CHECK(bleu_operation_wait(operation.ptr, 5000) == BLEU_STATUS_OK);
    const bleu_brightness_applied_t *applied = bleu_brightness_set_result(operation.ptr);
    CHECK(applied != nullptr && applied->raw == 48000);

    bleu_error_detail_t detail{};
    CHECK(bleu_last_error(&detail) == BLEU_STATUS_OK);
    CHECK(bleu_brightness_close(brightness) == BLEU_STATUS_OK);
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s <fake-root>\n", argv[0]);
        return 2;
    }
    CHECK(bleu_abi_version() == BLEU_ABI_VERSION);
    std::string root = argv[1];
    write_file(root + "/sys/class/power_supply/BAT0/status", "Charging\n");
    battery_checks(root);
    brightness_checks(root);
    std::printf(failures == 0 ? "capi_cxx: all checks passed\n" : "capi_cxx: %d check(s) failed\n", failures);
    return failures;
}
