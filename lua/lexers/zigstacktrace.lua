local lpeg = require('lpeg')

local lexer = require('lexers.lexer')
local token, word_match = lexer.token, lexer.word_match
local P, R, S = lpeg.P, lpeg.R, lpeg.S

local lex = lexer.new('zigstacktrace', {lex_by_line = true})

local ws = token(lexer.WHITESPACE, lexer.space^1)
lex:add_rule('whitespace', ws)

lex:add_rule('selector', token('selector', S('\t ')^0 * S('^~')^1))

lex:add_rule('diagnostic', token('diagnostic',
  (lexer.any-S(":"))^1 * P(":") * lexer.number * P(":") * lexer.number * P(":"))
  * lexer.space^1 * token(lexer.COMMENT, lexer.any^1))
lex:add_style('diagnostic', '$(style.bold)')

return lex
