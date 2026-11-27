extends RefCounted
## Exact legacy comment masking: preserve every character offset and LF.
## Keep the same regular expression and match semantics as the frozen adapters.

static func without_comments(code: String) -> String:
	var pattern := RegEx.new()
	pattern.compile("(?s)/\\*.*?\\*/|//[^\\n]*")
	var matches := pattern.search_all(code)
	var chunks := PackedStringArray()
	var cursor := 0
	for found: RegExMatch in matches:
		chunks.append(code.substr(cursor,found.get_start()-cursor))
		var lines := found.get_string().split("\n",true)
		for index in lines.size():
			lines[index] = " ".repeat(lines[index].length())
		chunks.append("\n".join(lines))
		cursor = found.get_end()
	chunks.append(code.substr(cursor))
	return "".join(chunks)
