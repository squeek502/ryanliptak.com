local lpeg = require('lpeg')

local lexer = require('lexers.lexer')
local token, word_match = lexer.token, lexer.word_match
local P, R, S = lpeg.P, lpeg.R, lpeg.S

local lex = lexer.new('poopresults', {lex_by_line = true})

lex:add_rule('benchmarkline', token('benchmark', P("Benchmark ") * lexer.number) * P(" ") * token(lexer.COMMENT, P("(") * lexer.number * P(" runs)")) * P(":") * lexer.any^1)
lex:add_style('benchmark', '$(style.bold)')

lex:add_rule('headerline', token('headerline', lexer.space^1 * P("measurement") * lexer.any^1))
lex:add_style('headerline', '$(style.bold)')

lex:add_rule('measurementline',
  token(lexer.WHITESPACE, lexer.space^1) * token('measurement', lexer.word) *
  token(lexer.WHITESPACE, lexer.space^1) * token('mean', lexer.number) * token(lexer.COMMENT, lexer.word^0) *
  token(lexer.WHITESPACE, lexer.space^1) * token('plusminus', P("±")) *
  token(lexer.WHITESPACE, lexer.space^1) * token('stddev', lexer.number) * token(lexer.COMMENT, lexer.word^0) *

  token(lexer.WHITESPACE, lexer.space^1) * token('min', lexer.number) * token(lexer.COMMENT, lexer.word^0) *
  token(lexer.WHITESPACE, lexer.space^1) * token('ellipsis', P("…")) *
  token(lexer.WHITESPACE, lexer.space^1) * token('max', lexer.number) * token(lexer.COMMENT, lexer.word^0) *

  token(lexer.WHITESPACE, lexer.space^1) * (token('outliers', lexer.number * lexer.space^1 * P("(1") * lexer.number * P"%)") + token(lexer.COMMENT, lexer.number * lexer.space^1 * lexer.range('(', ')', true, false, true))) *

  token(lexer.WHITESPACE, lexer.space^1) * (token('better', P("⚡") * lexer.any^1) + token('worse', P("💩") * lexer.any^1) + token(lexer.COMMENT, lexer.any^1))
)

return lex
