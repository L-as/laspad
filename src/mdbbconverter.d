// Converts markdown to BBCode.
// This way README.md files will be properly rendered
// on the Steam Workshop.

import std.regex;

const(char)[] markdown_to_bbcode(in char[] markdown) {
	auto link   = regex(r"\[(.*?)\]\((.*?)\)", "sg");
	auto code3  = regex(r"```(.*?)```",        "sg");
	auto code2  = regex(r"``(.*?)``",          "sg");
	auto code1  = regex(r"`(.*?)`",            "sg");
	auto h2     = regex(r"^##(.*)",           "mg");
	auto h1     = regex(r"^#(.*)",             "mg");
	auto bold   = regex(r"\*\*(.*?)\*\*",      "sg");
	auto italic = regex(r"\*(.*?)\*",          "sg");
	auto strike = regex(r"~~(.*?)~~",          "sg");

	return markdown
		.replaceAll(link,       r"[url=$2]$1[/url]")
		.replaceAll(code3,      r"[code]$1[/code]")
		.replaceAll(code2,      r"[code]$1[/code]")
		.replaceAll(code1,      r"[code]$1[/code]")
		.replaceAll(h2,         r"[b]$1[/b]")
		.replaceAll(h1,         r"[h1]$1[/h1]")
		.replaceAll(bold,       r"[b]$1[/b]")
		.replaceAll(italic,     r"[i]$1[/i]")
		.replaceAll(strike,     r"[strike]$1[/strike]")
	;
}
