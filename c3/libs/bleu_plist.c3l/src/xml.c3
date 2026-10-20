<*
 XML property lists: a reader and a writer for the XML form of the format.

 Source: Apple "PropertyList-1.0.dtd" (the element set, the required
 `<plist version="1.0">` root and the `<dict>` key/value pairing) and the
 "Property List Programming Guide". Cross-checked against CoreFoundation's
 `CFPropertyList.c` (https://github.com/apple-oss-distributions/CF), which
 rejects `<data>` that is not base64, parses ISO dates, reads a one-key
 `CF$UID` dictionary as a UID, and whose writer refuses UIDs; and against
 Python's `plistlib` (the golden fixtures). The reader uses the standard
 library's XML DOM (`std::encoding::xml`, a port of yxml), which resolves the
 five predefined entities and character references, merges CDATA into text, and
 ignores the DOCTYPE and comments.

 Not done: the writer writes dates without fractional seconds, as the format
 requires, and it refuses UIDs, as Apple's writer does.
*>
module bleu::plist::xml;
import bleu::error, bleu::plist::value, std::encoding::base64, std::encoding::xml, std::collections::list, std::collections::set, std::math;

<* The DOM node kinds of `std::encoding::xml`. *>
alias NodeKind = std::encoding::xml::XmlEventKind;

const String ROOT_ELEMENT = "plist";
const String UTF8_BOM = "\xEF\xBB\xBF";
const String BLANKS = " \t\r\n";
const String XML_DECLARATION = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
const String DOCTYPE = "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n";
const char TAB = '\t';
const char LINE_FEED = '\n';
const char CARRIAGE_RETURN = '\r';
const uint FIRST_CONTROL = 0x20;
const uint TAB_CODE = 0x09;
const uint LINE_FEED_CODE = 0x0A;
const uint CARRIAGE_RETURN_CODE = 0x0D;
const String TRUE_NAME = "true";
const String FALSE_NAME = "false";
const String KEY_NAME = "key";
const String UID_KEY = "CF$UID";

<*
 Parse an XML property list.

 @param [&inout] allocator : "Allocator for the value tree"
 @param text : "The complete document, UTF-8; a byte-order mark is allowed"
 @return? error::PROTOCOL : "The document is not well-formed XML, is not a plist, or holds a malformed value"
*>
fn Value? parse(Allocator allocator, String text)
{
	String source = text.starts_with(UTF8_BOM) ? text[UTF8_BOM.len:text.len - UTF8_BOM.len] : text;
	std::encoding::xml::XmlDocument*? document = std::encoding::xml::tparse(source);
	if (catch document) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "not well-formed XML")~;
	std::encoding::xml::XmlNode* root = document.root;
	if (!root || root.name != ROOT_ELEMENT) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "the root element is not <plist>")~;
	std::encoding::xml::XmlNode* element = null;
	foreach (child : root.children)
	{
		if (child.kind != NodeKind.START_ELEMENT) continue;
		if (element) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "<plist> holds more than one value")~;
		element = child;
	}
	if (!element) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "<plist> holds no value")~;
	return convert(allocator, element, 1);
}

<*
 Write `root` as an XML property list, version 1.0, UTF-8.

 @param [&inout] allocator : "Allocator for the document text"
 @return? error::INVALID_ARGUMENT : "A string holds a control character XML 1.0 cannot represent, or a real is not finite"
 @return? error::PROTOCOL : "The tree is nested deeper than the readers accept"
*>
fn String? write(Allocator allocator, Value* root)
{
	DString out;
	out.init(tmem);
	out.append_string(XML_DECLARATION);
	out.append_string(DOCTYPE);
	out.append_string("<plist version=\"1.0\">\n");
	emit(&out, root, 0)!;
	out.append_string("</plist>\n");
	return out.copy_str(allocator);
}

// The value of one element, converted to a Value in `allocator`.
fn Value? convert(Allocator allocator, std::encoding::xml::XmlNode* node, int depth) @local
{
	if (depth > value::MAX_NESTING) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "values are nested deeper than %d", value::MAX_NESTING)~;
	switch (node.name)
	{
		case "dict":    return dict_value(allocator, node, depth);
		case "array":   return array_value(allocator, node, depth);
		case "string":  return { .kind = STRING, .text = text_of(allocator, node)! };
		case "integer": return { .kind = INTEGER, .integer = integer_of(node)! };
		case "real":    return { .kind = REAL, .real = real_of(node)! };
		case "date":    return { .kind = DATE, .date = value::parse_date(trimmed(node)!)! };
		case "data":    return { .kind = DATA, .bytes = data_of(allocator, node)! };
		case "true":    return boolean_of(node, true);
		case "false":   return boolean_of(node, false);
		default:        return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "unknown element <%s>", node.name)~;
	}
}

fn Value? dict_value(Allocator allocator, std::encoding::xml::XmlNode* node, int depth) @local
{
	List{value::Member} members;
	members.tinit();
	HashSet{String} keys;
	keys.tinit();
	bool expecting_value = false;
	String key = "";
	foreach (child : node.children)
	{
		if (child.kind != NodeKind.START_ELEMENT) continue;
		if (!expecting_value)
		{
			if (child.name != KEY_NAME) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "dictionary member starts with <%s>, not <key>", child.name)~;
			key = text_of(allocator, child)!;
			expecting_value = true;
			continue;
		}
		Value member = convert(allocator, child, depth + 1)!;
		value::add_member(&members, &keys, key, member)!;
		expecting_value = false;
	}
	if (expecting_value) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "dictionary key '%s' has no value", key)~;
	Member[] found = members.to_aligned_array(allocator);
	// A dictionary whose only key is CF$UID with an integer is a UID, as in Apple's reader.
	if (found.len == 1 && found[0].key == UID_KEY && found[0].value.kind == INTEGER)
	{
		return { .kind = UID, .integer = found[0].value.integer };
	}
	return { .kind = DICT, .members = found };
}

fn Value? array_value(Allocator allocator, std::encoding::xml::XmlNode* node, int depth) @local
{
	List{Value} items;
	items.tinit();
	foreach (child : node.children)
	{
		if (child.kind != NodeKind.START_ELEMENT) continue;
		items.push(convert(allocator, child, depth + 1)!);
	}
	return { .kind = ARRAY, .items = items.to_aligned_array(allocator) };
}

// `<true/>` and `<false/>` must be empty.
fn Value? boolean_of(std::encoding::xml::XmlNode* node, bool truth) @local
{
	if (trimmed(node)!.len > 0) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "<%s> must be empty", node.name)~;
	return { .kind = BOOL, .boolean = truth };
}

fn long? integer_of(std::encoding::xml::XmlNode* node) @local
{
	String text = trimmed(node)!;
	if (try number = text.to_long()) return number;
	return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "<integer> '%s' is not a 64-bit number", text)~;
}

fn double? real_of(std::encoding::xml::XmlNode* node) @local
{
	String text = trimmed(node)!;
	if (try number = text.to_double()) return number;
	return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "<real> '%s' is not a number", text)~;
}

// The base64 content of a <data> element, decoded, with the whitespace the format allows removed.
fn char[]? data_of(Allocator allocator, std::encoding::xml::XmlNode* node) @local
{
	DString compact;
	compact.init(tmem);
	foreach (c : text_of(tmem, node)!)
	{
		if (!is_blank(c)) compact.append_char(c);
	}
	char[]? decoded = base64::decode(allocator, compact.str_view());
	if (catch decoded) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "<data> is not valid base64")~;
	return decoded;
}

// The character data of an element with no child elements, in `allocator`.
fn String? text_of(Allocator allocator, std::encoding::xml::XmlNode* node) @local
{
	DString out;
	out.init(tmem);
	foreach (child : node.children)
	{
		if (child.kind == NodeKind.TEXT) out.append_string(child.value);
		if (child.kind == NodeKind.START_ELEMENT) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "<%s> holds an element", node.name)~;
	}
	return out.copy_str(allocator);
}

// The character data of `node`, without surrounding blanks, in temporary memory.
fn String? trimmed(std::encoding::xml::XmlNode* node) @local
{
	String text = text_of(tmem, node)!;
	return text.trim(BLANKS);
}

fn bool is_blank(char c) @inline => c == ' ' || c == TAB || c == LINE_FEED || c == CARRIAGE_RETURN;

// Write one value at `depth`, each element on its own line, indented with tabs.
fn void? emit(DString* out, Value* value, int depth) @local
{
	if (depth > value::MAX_NESTING) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "values are nested deeper than %d", value::MAX_NESTING)~;
	switch (value.kind)
	{
		case DICT:    emit_dict(out, value, depth)!;
		case ARRAY:   emit_array(out, value, depth)!;
		case STRING:  emit_text(out, depth, "string", value.text)!;
		case INTEGER: emit_text(out, depth, "integer", string::tformat("%d", value.integer))!;
		case REAL:    emit_text(out, depth, "real", real_text(value.real)!)!;
		case DATE:    emit_text(out, depth, "date", value::format_date(tmem, value.date))!;
		case DATA:    emit_text(out, depth, "data", base64::tencode(value.bytes))!;
		case BOOL:    emit_empty(out, depth, value.boolean ? TRUE_NAME : FALSE_NAME);
		case UID:     return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "XML property lists cannot hold UIDs")~;
	}
}

fn void? emit_dict(DString* out, Value* value, int depth) @local
{
	if (value.members.len == 0)
	{
		emit_indent(out, depth);
		out.append_string("<dict/>\n");
		return;
	}
	emit_indent(out, depth);
	out.append_string("<dict>\n");
	foreach (&member : value.members)
	{
		emit_indent(out, depth + 1);
		out.append_string("<key>");
		escape_into(out, member.key)!;
		out.append_string("</key>\n");
		emit(out, &member.value, depth + 1)!;
	}
	emit_indent(out, depth);
	out.append_string("</dict>\n");
}

fn void? emit_array(DString* out, Value* value, int depth) @local
{
	if (value.items.len == 0)
	{
		emit_indent(out, depth);
		out.append_string("<array/>\n");
		return;
	}
	emit_indent(out, depth);
	out.append_string("<array>\n");
	foreach (&item : value.items) emit(out, item, depth + 1)!;
	emit_indent(out, depth);
	out.append_string("</array>\n");
}

// A UID is written as the dictionary XML archives use for it.
fn void? emit_uid(DString* out, int depth, long uid) @local
{
	emit_indent(out, depth);
	out.append_string("<dict>\n");
	emit_indent(out, depth + 1);
	out.append_string(string::tformat("<key>%s</key>\n", UID_KEY));
	emit_text(out, depth + 1, "integer", string::tformat("%d", uid))!;
	emit_indent(out, depth);
	out.append_string("</dict>\n");
}

fn void? emit_text(DString* out, int depth, String element, String content) @local
{
	emit_indent(out, depth);
	out.append_string(string::tformat("<%s>", element));
	escape_into(out, content)!;
	out.append_string(string::tformat("</%s>\n", element));
}

fn void emit_empty(DString* out, int depth, String element) @local
{
	emit_indent(out, depth);
	out.append_string(string::tformat("<%s/>\n", element));
}

fn void emit_indent(DString* out, int depth) @local
{
	for (int i = 0; i < depth; i++) out.append_char(TAB);
}

// `text` with the XML markup characters escaped. Control characters XML 1.0 cannot
// hold are refused; carriage returns are written as a reference so they survive.
fn void? escape_into(DString* out, String text) @local
{
	foreach (c : text)
	{
		switch (c)
		{
			case '&': out.append_string("&amp;");
			case '<': out.append_string("&lt;");
			case '>': out.append_string("&gt;");
			case CARRIAGE_RETURN: out.append_string("&#xD;");
			default:
				if (c < FIRST_CONTROL && c != TAB && c != LINE_FEED)
				{
					return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "XML 1.0 cannot represent control character 0x%02X", (uint)c)~;
				}
				out.append_char(c);
		}
	}
}

// A real in the shortest of 15, 16 or 17 significant digits that reads back exactly.
fn String? real_text(double number) @local
{
	if (math::is_nan(number) || math::is_inf(number)) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "a non-finite real cannot be written")~;
	String fifteen = string::tformat("%.15g", number);
	if (fifteen.to_double()!! == number) return fifteen;
	String sixteen = string::tformat("%.16g", number);
	if (sixteen.to_double()!! == number) return sixteen;
	return string::tformat("%.17g", number);
}
