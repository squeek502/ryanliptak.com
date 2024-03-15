local lpeg = require('lpeg')

local lexer = require('lexers.lexer')
local token, word_match = lexer.token, lexer.word_match
local P, R, S = lpeg.P, lpeg.R, lpeg.S

local lex = lexer.new('zigstacktrace', {lex_by_line = true})

lex:add_rule(lexer.OPERATOR, token(lexer.OPERATOR, S("$>")) * lexer.space * token(lexer.KEYWORD, lexer.any^1))
lex:add_style(lexer.OPERATOR, '$(style.important)')

lex:add_rule('any_line', token(lexer.DEFAULT, lexer.any^1))

return lex
