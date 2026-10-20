<*
 The Windows backend: each keyring request as one Credential Manager call.

 Credentials are generic, persist on this machine only, and are named
 "bleu:<service>:<account>" (see `local_names.c3`). The secret is written as the
 credential's blob, exactly as given; the library does not add a text encoding.
 Credential Manager has no lock, so UNLOCK fails with UNSUPPORTED.

 Compiled only (no Windows machine here). Failures carry the GetLastError code
 in `error::last()`.
*>
module bleu::secrets::win @feat(WIN32);
import std::collections::list, std::collections::maybe, std::os::win32, bleu::error, bleu::win::errors, bleu::win::text, bleu::observe, bleu::operation, bleu::secrets, bleu::secrets::cred, bleu::secrets::local, bleu::service;

<* Run one command and complete its operation. *>
fn void execute(void* state, KeyringHub* hub, Command* command)
{
	switch (command.kind)
	{
		case STORE: run_store(hub, command);
		case READ: run_read(command);
		case DELETE: run_delete(hub, command);
		case SEARCH: run_search(command);
		case UNLOCK: run_unlock(command);
	}
}

fn void run_store(KeyringHub* hub, Command* command)
{
	Operation{Entry}* op = (Operation{Entry}*)command.operation;
	defer op.release();
	Entry? stored = store(command.entry, command.value);
	if (catch err = stored)
	{
		op.fail(err);
		return;
	}
	secrets::emit_local(hub, STORED, command.entry.service, command.entry.account);
	op.succeed(stored);
}

fn void run_read(Command* command)
{
	Operation{Secret}* op = (Operation{Secret}*)command.operation;
	defer op.release();
	Secret? secret = read_secret(command.entry, op.allocator());
	if (catch err = secret)
	{
		op.fail(err);
		return;
	}
	op.succeed(secret);
}

fn void run_delete(KeyringHub* hub, Command* command)
{
	Operation{bool}* op = (Operation{bool}*)command.operation;
	defer op.release();
	bool? removed = delete_entry(command.entry);
	if (catch err = removed)
	{
		op.fail(err);
		return;
	}
	if (removed) secrets::emit_local(hub, DELETED, command.entry.service, command.entry.account);
	op.succeed(removed);
}

fn void run_search(Command* command)
{
	Operation{Entry[]}* op = (Operation{Entry[]}*)command.operation;
	defer op.release();
	Entry[]? found = search_entries(command.entry, op.allocator());
	if (catch err = found)
	{
		op.fail(err);
		return;
	}
	op.succeed(found);
}

fn void run_unlock(Command* command)
{
	Operation{Lock}* op = (Operation{Lock}*)command.operation;
	defer op.release();
	op.fail(error::UNSUPPORTED);
}

<* Write the credential. The entry is copied by the operation already; this only builds the native structs. *>
fn Entry? store(Entry entry, Secret value)
{
	if (value.bytes.len > cred::CRED_MAX_CREDENTIAL_BLOB_SIZE)
	{
		return error::raise(
			error::OUT_OF_RANGE,
			error::Domain.INTERNAL,
			0,
			"a Credential Manager secret holds at most 2560 bytes"
		)~;
	}
	if (entry.attributes.len > cred::CRED_MAX_ATTRIBUTES)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"too many attributes for one credential"
		)~;
	}
	String target_text               = local::target_name(tmem, entry.service, entry.account)!;
	WideZ target                     = text::to_wide(tmem, target_text)!;
	WideZ user                       = text::to_wide(tmem, entry.account)!;
	WideZ comment                    = text::to_wide(tmem, entry.label)!;
	WideZ[] keywords                 = alloc::alloc_array(tmem, WideZ, entry.attributes.len);
	CredentialAttribute[] attributes = alloc::alloc_array(tmem, CredentialAttribute, entry.attributes.len);
	foreach (i, attribute : entry.attributes)
	{
		keywords[i] = text::to_wide(tmem, attribute.key)!;
		attributes[i] = {
			.keyword = keywords[i].as_wstring(),
			.value_size = (Win32_DWORD)attribute.value.len,
			.value = attribute.value.ptr
		};
	}
	Credential credential = {
		.type = cred::CRED_TYPE_GENERIC,
		.target_name = target.as_wstring(),
		.comment = comment.as_wstring(),
		.blob_size = (Win32_DWORD)value.bytes.len,
		.blob = value.bytes.ptr,
		.persist = cred::CRED_PERSIST_LOCAL_MACHINE,
		.attribute_count = (Win32_DWORD)attributes.len,
		.attributes = attributes.ptr,
		.user_name = user.as_wstring(),
	};
	if (cred::cred_write(&credential, 0) == 0) return errors::raise_last("CredWriteW")~;
	return entry;
}

<* The secret of the credential, copied into `allocator`. *>
fn Secret? read_secret(Entry entry, Allocator allocator)
{
	String target_text = local::target_name(tmem, entry.service, entry.account)!;
	WideZ target       = text::to_wide(tmem, target_text)!;
	Credential* found  = null;
	if (cred::cred_read(target.as_wstring(), cred::CRED_TYPE_GENERIC, 0, &found) == 0)
	{
		if (win32::getLastError() == cred::ERROR_NOT_FOUND) return NOT_FOUND~;
		return errors::raise_last("CredReadW")~;
	}
	defer cred::cred_free(found);
	// Declared after the free, so it runs first: the blob is zeroed before CredFree gives the memory back.
	defer wipe_blob(found);
	char[] bytes  = found.blob[0:(sz)found.blob_size];
	Secret secret = { .bytes = alloc::clone_slice(allocator, bytes) };
	return secret;
}

<*
 Zero the secret blob of one native credential. CredFree releases the memory without clearing it, so
 the library clears it first.
*>
fn void wipe_blob(Credential* native) @private
{
	if (native.blob != null && native.blob_size > 0) mem::set((void*)native.blob, 0, (sz)native.blob_size, 0, true);
}

<* Zero the secret blobs of an enumerated array of `count` credentials, before CredFree releases them. *>
fn void wipe_blobs(Credential** found, Win32_DWORD count) @private
{
	for (usz i = 0; i < count; i++) wipe_blob(found[i]);
}

<* Delete the credential. False when there was none. *>
fn bool? delete_entry(Entry entry)
{
	String target_text = local::target_name(tmem, entry.service, entry.account)!;
	WideZ target       = text::to_wide(tmem, target_text)!;
	if (cred::cred_delete(target.as_wstring(), cred::CRED_TYPE_GENERIC, 0) == 0)
	{
		if (win32::getLastError() == cred::ERROR_NOT_FOUND) return false;
		return errors::raise_last("CredDeleteW")~;
	}
	return true;
}

<* Every credential named "bleu:*" whose service, account and attributes match `filter`. *>
fn Entry[]? search_entries(Entry filter, Allocator allocator)
{
	WideZ pattern      = text::to_wide(tmem, "bleu:*")!;
	Win32_DWORD count  = 0;
	Credential** found = null;
	if (cred::cred_enumerate(pattern.as_wstring(), 0, &count, &found) == 0)
	{
		if (win32::getLastError() == cred::ERROR_NOT_FOUND) return { };
		return errors::raise_last("CredEnumerateW")~;
	}
	defer cred::cred_free(found);
	defer wipe_blobs(found, count);
	List{Entry} matches;
	matches.init(tmem);
	for (usz i = 0; i < count; i++)
	{
		// A credential whose name this library did not write is not ours: skip it.
		if (try entry = entry_of(found[i], allocator))
		{
			if (matches_filter(entry, filter)) matches.push(entry);
		}
	}
	return alloc::clone_slice(allocator, matches.array_view());
}

// The entry a native credential describes, or NOT_FOUND for one this library did not write.
fn Entry? entry_of(Credential* native, Allocator allocator)
{
	String target = text::from_wide(tmem, native.target_name)!;
	String service;
	String account;
	local::split_target(allocator, target, &service, &account)!;
	List{Attribute} attributes;
	attributes.init(allocator);
	for (usz i = 0; i < native.attribute_count; i++)
	{
		CredentialAttribute* attribute = &native.attributes[i];
		String key                     = text::from_wide(tmem, attribute.keyword)!;
		String value                   = (String)attribute.value[0:(sz)attribute.value_size];
		attributes.push({ .key = key.copy(allocator), .value = value.copy(allocator) });
	}
	ulong last_written = ((ulong)native.last_written.high << 32) | native.last_written.low;
	Entry entry = {
		.service = service,
		.account = account,
		.label = text::from_wide(allocator, native.comment) ?? "",
		.attributes = attributes.array_view(),
		.modified = maybe::value(local::filetime_to_time(last_written)),
	};
	return entry;
}

// Whether `entry` has the filter's service and account (when given) and every filter attribute.
fn bool matches_filter(Entry entry, Entry filter)
{
	if (filter.service.len > 0 && entry.service != filter.service) return false;
	if (filter.account.len > 0 && entry.account != filter.account) return false;
	foreach (wanted : filter.attributes)
	{
		bool found = false;
		foreach (have : entry.attributes)
		{
			if (have.key == wanted.key && have.value == wanted.value) found = true;
		}
		if (!found) return false;
	}
	return true;
}