<*
 The macOS backend: each keyring request as one call to the login keychain.

 An entry is a generic password whose service is "bleu:<service>" and whose
 account is the account. The label is the keychain label; the attributes are
 hex-encoded in the item's comment (see `local_blob.c3`), because lookups by
 attribute are done here, not by the keychain.

 Search lists the generic passwords of the login keychain and keeps the ones
 named "bleu:". Each call may show the keychain's own access prompt; the library
 cannot bound or observe that prompt, so a call can block while it is open.

 Compiled only (no macOS machine here).
*>
module bleu::secrets::mac @feat(DARWIN);
import std::collections::list, std::collections::maybe, bleu::cf, bleu::error, bleu::observe, bleu::operation, bleu::secrets, bleu::secrets::keychain, bleu::secrets::local, bleu::service;

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

// The keychain service name of an entry: the prefix, then the service.
fn String service_name(Allocator allocator, String service)
{
	return string::tformat("%s%s", local::NAME_PREFIX, service).copy(allocator);
}

// Fail with the keychain status as the native code, recorded in `error::last()`.
fn fault status_failure(int status, String call)
{
	return error::raise(
		keychain::status_fault(status),
		error::Domain.INTERNAL,
		status,
		"%s returned OSStatus %d",
		call,
		status
	);
}

<* Add the item, or update it when an item with the same service and account exists. *>
fn Entry? store(Entry entry, Secret value)
{
	cf::Ref service = cf::from_string(service_name(tmem, entry.service));
	defer service.close();
	cf::Ref account = cf::from_string(entry.account);
	defer account.close();
	cf::Ref label = cf::from_string(entry.label);
	defer label.close();
	cf::Ref comment = cf::from_string(local::hex_encode(tmem, local::encode_attributes(tmem, entry.attributes)));
	defer comment.close();
	cf::Ref data = cf::from_bytes(value.bytes);
	defer data.close();

	cf::CFTypeRef[6] keys   = {
		keychain::KSEC_CLASS,
		keychain::KSEC_ATTR_SERVICE,
		keychain::KSEC_ATTR_ACCOUNT,
		keychain::KSEC_ATTR_LABEL,
		keychain::KSEC_ATTR_COMMENT,
		keychain::KSEC_VALUE_DATA
	};
	cf::CFTypeRef[6] values = {
		keychain::KSEC_CLASS_GENERIC_PASSWORD,
		service.ptr,
		account.ptr,
		label.ptr,
		comment.ptr,
		data.ptr
	};
	cf::Ref add             = keychain::dictionary(keys[..], values[..]);
	defer add.close();
	int status = keychain::sec_item_add(add.ptr, null);
	if (status == keychain::ERR_SEC_DUPLICATE_ITEM)
	{
		status = update_item(&service, &account, &label, &comment, &data);
		if (status != keychain::ERR_SEC_SUCCESS) return status_failure(status, "SecItemUpdate")~;
		return entry;
	}
	if (status != keychain::ERR_SEC_SUCCESS) return status_failure(status, "SecItemAdd")~;
	return entry;
}

fn int update_item(cf::Ref* service, cf::Ref* account, cf::Ref* label, cf::Ref* comment, cf::Ref* data)
{
	cf::CFTypeRef[3] match_keys   = { keychain::KSEC_CLASS, keychain::KSEC_ATTR_SERVICE, keychain::KSEC_ATTR_ACCOUNT };
	cf::CFTypeRef[3] match_values = { keychain::KSEC_CLASS_GENERIC_PASSWORD, service.ptr, account.ptr };
	cf::Ref match                 = keychain::dictionary(match_keys[..], match_values[..]);
	defer match.close();
	cf::CFTypeRef[3] change_keys   = {
		keychain::KSEC_VALUE_DATA,
		keychain::KSEC_ATTR_LABEL,
		keychain::KSEC_ATTR_COMMENT
	};
	cf::CFTypeRef[3] change_values = { data.ptr, label.ptr, comment.ptr };
	cf::Ref changes                = keychain::dictionary(change_keys[..], change_values[..]);
	defer changes.close();
	return keychain::sec_item_update(match.ptr, changes.ptr);
}

// The query that names one entry.
fn cf::Ref entry_query(Entry entry, cf::Ref* service, cf::Ref* account)
{
	cf::CFTypeRef[3] keys   = { keychain::KSEC_CLASS, keychain::KSEC_ATTR_SERVICE, keychain::KSEC_ATTR_ACCOUNT };
	cf::CFTypeRef[3] values = { keychain::KSEC_CLASS_GENERIC_PASSWORD, service.ptr, account.ptr };
	return keychain::dictionary(keys[..], values[..]);
}

<* The secret of the entry, copied into `allocator`. *>
fn Secret? read_secret(Entry entry, Allocator allocator)
{
	cf::Ref service = cf::from_string(service_name(tmem, entry.service));
	defer service.close();
	cf::Ref account = cf::from_string(entry.account);
	defer account.close();
	cf::CFTypeRef[4] keys = {
		keychain::KSEC_CLASS,
		keychain::KSEC_ATTR_SERVICE,
		keychain::KSEC_ATTR_ACCOUNT,
		keychain::KSEC_RETURN_DATA
	};
	cf::Ref yes           = cf::from_bool(true);
	defer yes.close();
	cf::CFTypeRef[4] values = { keychain::KSEC_CLASS_GENERIC_PASSWORD, service.ptr, account.ptr, yes.ptr };
	cf::Ref query           = keychain::dictionary(keys[..], values[..]);
	defer query.close();
	cf::CFTypeRef result = null;
	int status           = keychain::sec_item_copy_matching(query.ptr, &result);
	cf::Ref owned        = cf::adopt(result);
	defer owned.close();
	if (status == keychain::ERR_SEC_ITEM_NOT_FOUND) return NOT_FOUND~;
	if (status != keychain::ERR_SEC_SUCCESS) return status_failure(status, "SecItemCopyMatching")~;
	char[] bytes  = cf::data_bytes(owned.ptr, allocator)!;
	Secret secret = { .bytes = bytes };
	return secret;
}

<* Delete the entry. False when there was none. *>
fn bool? delete_entry(Entry entry)
{
	cf::Ref service = cf::from_string(service_name(tmem, entry.service));
	defer service.close();
	cf::Ref account = cf::from_string(entry.account);
	defer account.close();
	cf::Ref query = entry_query(entry, &service, &account);
	defer query.close();
	int status = keychain::sec_item_delete(query.ptr);
	if (status == keychain::ERR_SEC_ITEM_NOT_FOUND) return false;
	if (status != keychain::ERR_SEC_SUCCESS) return status_failure(status, "SecItemDelete")~;
	return true;
}

<* Every "bleu:" generic password whose service and account match `filter`. *>
fn Entry[]? search_entries(Entry filter, Allocator allocator)
{
	cf::CFTypeRef[3] keys = { keychain::KSEC_CLASS, keychain::KSEC_RETURN_ATTRIBUTES, keychain::KSEC_MATCH_LIMIT };
	cf::Ref yes           = cf::from_bool(true);
	defer yes.close();
	cf::CFTypeRef[3] values = { keychain::KSEC_CLASS_GENERIC_PASSWORD, yes.ptr, keychain::KSEC_MATCH_LIMIT_ALL };
	cf::Ref query           = keychain::dictionary(keys[..], values[..]);
	defer query.close();
	cf::CFTypeRef result = null;
	int status           = keychain::sec_item_copy_matching(query.ptr, &result);
	cf::Ref owned        = cf::adopt(result);
	defer owned.close();
	if (status == keychain::ERR_SEC_ITEM_NOT_FOUND) return { };
	if (status != keychain::ERR_SEC_SUCCESS) return status_failure(status, "SecItemCopyMatching")~;
	List{Entry} matches;
	matches.init(tmem);
	for (sz i = 0; i < cf::array_count(owned.ptr); i++)
	{
		// Items that are not ours (another application's, or malformed) are skipped.
		if (try entry = entry_of(cf::array_at(owned.ptr, i), allocator))
		{
			if (matches_filter(entry, filter)) matches.push(entry);
		}
	}
	return alloc::clone_slice(allocator, matches.array_view());
}

// The entry a keychain attribute dictionary describes, or NOT_FOUND for an item that is not ours.
fn Entry? entry_of(cf::CFTypeRef dictionary, Allocator allocator)
{
	sz count               = cf::dictionary_count(dictionary);
	cf::CFTypeRef[] keys   = alloc::alloc_array(tmem, cf::CFTypeRef, count);
	cf::CFTypeRef[] values = alloc::alloc_array(tmem, cf::CFTypeRef, count);
	cf::dictionary_entries(dictionary, keys, values);
	String raw_service = "";
	String account     = "";
	String label       = "";
	String comment     = "";
	String key_service = cf::string_value(keychain::KSEC_ATTR_SERVICE, tmem) ?? "";
	String key_account = cf::string_value(keychain::KSEC_ATTR_ACCOUNT, tmem) ?? "";
	String key_label   = cf::string_value(keychain::KSEC_ATTR_LABEL, tmem) ?? "";
	String key_comment = cf::string_value(keychain::KSEC_ATTR_COMMENT, tmem) ?? "";
	for (sz i = 0; i < count; i++)
	{
		String key = cf::string_value(keys[i], tmem) ?? "";
		if (key == key_service)
		{
			raw_service = cf::string_value(values[i], allocator) ?? "";
		}
		if (key == key_account)
		{
			account = cf::string_value(values[i], allocator) ?? "";
		}
		if (key == key_label)
		{
			label = cf::string_value(values[i], allocator) ?? "";
		}
		if (key == key_comment)
		{
			comment = cf::string_value(values[i], tmem) ?? "";
		}
	}
	if (!raw_service.starts_with(local::NAME_PREFIX)) return NOT_FOUND~;
	List{Attribute} attributes;
	attributes.init(allocator);
	if (try blob = local::hex_decode(tmem, comment))
	{
		if (try decoded = local::decode_attributes(tmem, (String)blob))
		{
			foreach (attribute : decoded) attributes.push(
				{ .key = attribute.key.copy(allocator), .value = attribute.value.copy(allocator) }
			);
		}
	}
	Entry entry = {
		.service = raw_service[local::NAME_PREFIX.len:raw_service.len - local::NAME_PREFIX.len].copy(allocator),
		.account = account,
		.label = label,
		.attributes = attributes.array_view(),
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