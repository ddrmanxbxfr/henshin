-module(henshin_module).

-include_lib("parse_trans/include/codegen.hrl").

%% Interface

-export([format_error/1, parse_transform/2]).
-export_type([error/0]).

-type error() :: binary_generator | parameterized_module.

%% Implementation

-spec format_error(error()) -> io_lib:chars().
format_error(binary_generator) ->
    "binary generators illegal in henshin rules";
format_error(parameterized_module) ->
    "parameterized modules are not supported by henshin".

-spec parse_transform(erl_syntax:forms(), [compile:option()]) ->
    erl_syntax:forms().
parse_transform(Forms, _CompileOpts) ->
    {LastFileForm, _ModName, BeforeModForms, AfterModForms, ModErrors} =
        analyze_module(Forms),
    {LastFileForm2, AttrForms, Rest} =
        split_until_last_attr(AfterModForms, LastFileForm),
    Rules = analyze_rules(Forms),
    ThisFileForm = file_form(?FILE),
    TransformedForms = transform_rules(Rest),
    []
        ++ BeforeModForms
        ++ erl_syntax:revert_forms(ModErrors)
        ++ [ThisFileForm]
        ++ [export_form([{henshin_rules, 0} | Rules], ?LINE)]
        ++ [LastFileForm]
        ++ AttrForms
        ++ [ThisFileForm]
        ++ [henshin_rules_form(Rules)]
        ++ [LastFileForm2]
        ++ TransformedForms.

%% Internal

analyze_module(Rules) ->
    analyze_module(Rules, {attribute, 0, file, {"nofile", 1}}, make_ref(), []).

analyze_module(Forms = [Form | Rest], File, ModName, Before) ->
    case erl_syntax:type(Form) of
        attribute ->
            case erl_syntax_lib:analyze_attribute(Form) of
                {module, {Name, _Args}} ->
                    Error = henshin_lib:marker(
                        error, ?MODULE, parameterized_module, Form),
                    {File, Name, lists:reverse(Before, [Form]), Rest, [Error]};
                {module, Name} ->
                    {File, Name, lists:reverse(Before, [Form]), Rest, []};
                {file, _} ->
                    analyze_module(Rest, Form, ModName, [Form | Before]);
                _ ->
                    {File, ModName, Before, Forms, []}
            end;
        error_marker ->
            analyze_module(Rest, File, ModName, [Form | Before]);
        _ ->
            {File, ModName, Before, Forms, []}
    end;
analyze_module([], File, ModName, Before) ->
    {File, ModName, [File], lists:reverse(Before), []}.

analyze_rules(Forms) ->
    lists:usort(
        lists:flatmap(
            fun (Form) ->
                case erl_syntax:type(Form) of
                    rule -> [erl_syntax_lib:analyze_rule(Form)];
                    _ -> []
                end
            end, Forms)).

arity_qualifier(Name, Arity) ->
    erl_syntax:arity_qualifier(
        erl_syntax:atom(Name),
        erl_syntax:integer(Arity)).

export_form(NAs, Line) ->
    erl_syntax:revert(erl_syntax_lib:map(
        fun (Node) -> erl_syntax:set_pos(Node, Line) end,
        erl_syntax:attribute(
            erl_syntax:atom(export),
            [erl_syntax:list([ arity_qualifier(N, A) || {N, A} <- NAs ])]))).

file_form(File) ->
    erl_syntax:revert(
        erl_syntax:set_pos(
            erl_syntax:attribute(
                erl_syntax:atom(file),
                [erl_syntax:abstract({File, 1})]),
            1)).

henshin_rules_form(NAs) ->
    codegen:gen_function(henshin_rules, fun () -> {'$var', NAs} end).

split_until_last_attr(Forms, File) ->
    split_until_last_attr(Forms, File, []).

split_until_last_attr(Forms = [Form | Rest], File, Before) ->
    case erl_syntax:type(Form) of
        attribute ->
            split_until_last_attr(Rest, File, [Form | Before]);
        _ ->
            {File, lists:reverse(Before), Forms}
    end;
split_until_last_attr([], File, Before) ->
    {File, lists:reverse(Before), []}.

transform_binary_generator(Gen) ->
    erl_syntax:copy_pos(
        Gen,
        erl_syntax:match_expr(
            erl_syntax:binary_generator_pattern(Gen),
            erl_syntax:binary_generator_body(Gen))).

transform_generator(Gen) ->
    Body = erl_syntax:generator_body(Gen),
    [Call] = codegen:exprs(fun () -> erl_syntax:concrete({'$form', Body}) end),
    % erl_syntax:set_pos/1 does not seem to work on erl_parse terms, so Call
    % need to be reconstructed into an erl_syntax term for the position to be
    % set correctly.
    % See https://github.com/richcarl/syntax_tools/commit/554e2f
    erl_syntax:copy_pos(
        Gen,
        erl_syntax:match_expr(
            erl_syntax:generator_pattern(Gen),
            erl_syntax:copy_pos(
                Gen,
                erl_syntax:application(
                    erl_syntax:application_operator(Call),
                    erl_syntax:application_arguments(Call))))).

transform_rules(Forms) ->
    lists:flatmap(
        fun (Form) ->
            case erl_syntax:type(Form) of
                rule ->
                    {Rule, Errors} = transform_rule(Form),
                    [Rule | Errors];
                _ ->
                    [Form]
            end
        end, Forms).

transform_rule(Rule) ->
    {Clauses, Errors} = transform_rule_clauses(erl_syntax:rule_clauses(Rule)),
    Function = erl_syntax:copy_pos(
        Rule,
        erl_syntax:function(erl_syntax:rule_name(Rule), Clauses)),
    {erl_syntax:revert(Function), erl_syntax:revert_forms(Errors)}.

transform_rule_clauses(Clauses) ->
    lists:mapfoldr(
        fun (Clause, Errors) ->
            {Body, Errors2} = lists:mapfoldr(
                fun (Expr, Errors3) ->
                    case erl_syntax:type(Expr) of
                        binary_generator ->
                            Match = transform_binary_generator(Expr),
                            Error = henshin_lib:marker(
                                error, ?MODULE, binary_generator, Expr),
                            {Match, [Error | Errors3]};
                        generator ->
                            {transform_generator(Expr), Errors3};
                        _ ->
                            {Expr, Errors3}
                    end
                end, Errors, erl_syntax:clause_body(Clause)),
            NewClause = erl_syntax:clause(
                erl_syntax:clause_patterns(Clause),
                erl_syntax:clause_guard(Clause),
                Body),
            {NewClause, Errors2}
        end, [], Clauses).
