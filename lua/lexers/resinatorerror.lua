local lpeg = require('lpeg')

local lexer = require('lexers.lexer')
local token, word_match = lexer.token, lexer.word_match
local P, R, S = lpeg.P, lpeg.R, lpeg.S

local lex = lexer.new('zigstacktrace', {lex_by_line = true})

lex:add_rule('selector', token('selector', S('\t ')^0 * P("^") * P("~")^0 * lexer.newline))

lex:add_rule('diagnostic', token('diagnostic',
  (lexer.any-S(":"))^1 * P(":") * lexer.number * P(":") * lexer.number * P(":"))
  * lexer.space^1
  * (token('error', P("error:")) + token('note', P("note:")) + token('warning', P("warning:")))
  * lexer.space^1 * token('diagnostic', lexer.any^1))
lex:add_style('diagnostic', '$(style.bold)')
lex:add_style('error', '$(style.bold)')
lex:add_style('note', '$(style.bold)')
lex:add_style('warning', '$(style.bold)')

return lex
