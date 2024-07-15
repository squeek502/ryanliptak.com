local lpeg = require('lpeg')
-- Copyright 2006-2020 Mitchell mitchell.att.foicica.com. See License.txt.
-- C LPeg lexer.

local lexer = require('lexers.lexer')
local token, word_match = lexer.token, lexer.word_match
local P, R, S = lpeg.P, lpeg.R, lpeg.S

local lex = lexer.new('ansi_c')

-- Whitespace.
local ws = token(lexer.WHITESPACE, lexer.space^1)
lex:add_rule('whitespace', ws)

-- Keywords.
lex:add_rule('keyword', token(lexer.KEYWORD, word_match[[
  ACCELERATORS BITMAP CURSOR DIALOG DIALOGEX DLGINCLUDE DLGINIT FONT
  HTML ICON MENU MENUEX MESSAGETABLE PLUGPLAY RCDATA STRINGTABLE
  TOOLBAR VERSIONINFO VXD CHARACTERISTICS LANGUAGE VERSION
  CAPTION CLASS EXSTYLE STYLE
  AUTO3STATE AUTOCHECKBOX AUTORADIOBUTTON
  CHECKBOX COMBOBOX CONTROL CTEXT DEFPUSHBUTTON EDITTEXT HEDIT
  IEDIT GROUPBOX ICON LISTBOX LTEXT PUSHBOX PUSHBUTTON RADIOBUTTON
  RTEXT SCROLLBAR STATE3 USERBUTTON BUTTON EDIT STATIC LISTBOX
  MENUITEM POPUP SEPARATOR CHECKED GRAYED HELP INACTIVE MENUBARBREAK
  MENUBREAK FILEVERSION PRODUCTVERSION FILEFLAGSMASK FILEFLAGS
  FILEOS FILETYPE FILESUBTYPE BLOCK VALUE
]]))

-- Types.
--lex:add_rule('type', token(lexer.TYPE, word_match[[]])

-- Constants.
lex:add_rule('constants', token(lexer.CONSTANT, word_match[[
  NULL
  PRELOAD LOADONCALL FIXED MOVEABLE DISCARDABLE PURE IMPURE SHARED NONSHARED
  VIRTKEY ASCII NOINVERT ALT SHIFT CONTROL
]]))

lex:add_rule('begin_and_end', token('punctuation', word_match[[BEGIN END]]))
lex:add_rule('not', token('operator', word_match[[NOT]]))

-- Identifiers.
local identifier = (lexer.alnum + '_')^1
lex:add_rule('identifier', token(lexer.IDENTIFIER, identifier))

-- Strings.
local dq_str = P('L')^-1 * lexer.range('"', false, false)
lex:add_rule('string', token(lexer.STRING, dq_str))

-- Comments.
local line_comment = lexer.to_eol('//', true)
local block_comment = lexer.range('/*', '*/') +
  lexer.range('#if' * S(' \t')^0 * '0' * lexer.space, '#endif')
lex:add_rule('comment', token(lexer.COMMENT, line_comment + block_comment))

-- Numbers.
--lex:add_rule('number', token(lexer.NUMBER, lexer.number))

-- Preprocessor.
local include = token(lexer.PREPROCESSOR, '#' * S('\t ')^0 * 'include') *
  (ws * token(lexer.STRING, lexer.range('<', '>', true)))^-1
local preproc = token(lexer.PREPROCESSOR, '#' * S('\t ')^0 * word_match[[
  define elif else endif if ifdef ifndef line pragma undef
]])
lex:add_rule('preprocessor', include + preproc)

lex:add_rule('punctuation', token('punctuation', S(':;,.()[]{}')))

-- Operators.
lex:add_rule('operator', token(lexer.OPERATOR, S('+-/*%<>~!=^&|?~')))

return lex
