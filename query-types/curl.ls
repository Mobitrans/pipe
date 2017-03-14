{bindP, from-error-value-callback, new-promise, returnP, to-callback, with-cancel-and-dispose} = require \../async-ls
config = require \./../config
{concat-map, each, find, filter, group-by, id, Obj, keys, map, obj-to-pairs, Str} = require \prelude-ls
{exec} = require \shelljs
{compile-and-execute-sync} = require \transpilation

# keywords :: (CancellablePromise cp) => [DataSource, String] -> cp [String]
export keywords = ([data-source]) ->
    returnP keywords: <[curl -H -d -X POST GET --user http:// https://]>

# get-context :: a -> Context
export get-context = ->
    {} <<< (require \./default-query-context.ls)! <<< (require \prelude-ls)

# for executing a single mongodb query POSTed from client
# execute :: (CancellablePromise cp) => OpsManager -> QueryStore -> DataSource -> String -> String -> Parameters -> cp result
export execute = (, , data-source, query, transpilation-language, parameters) -->
    {shell-command, parse} = require \./shell-command-parser
    result = parse shell-command, (query.replace /\s/g, '')

    # parsing error
    if !!result.0.1
        return (new-promise (, rej) -> rej new Error "Parsing Error #{result.0.1}")

    result := result.0.0.args
        |> concat-map id

    url = result
        |> find (-> !!it.opt)
        |> (.opt)

    options = result
        |> filter (-> !!it.name)
        |> map ({name, value}) ->
            (if name.length > 1 then "--" else "-") + name + if !!value then " #value" else ""
        |> Str.join " "

    [err, url] = compile-and-execute-sync do
        url
        transpilation-language
        parameters |> Obj.map -> it ? ""

    if !!err
        return (new-promise (, rej) -> rej new Error "Url foramtting failed\n#err")

    # escape characters
    url .= replace \{, '\\{'
    url .= replace \}, '\\}'

    curl-process = null

    execute-curl = new-promise (res, rej) ->
        console.log "curl -s '#url' #{options}"
        curl-process := exec "curl -s '#url' #{options}", silent: true, (code, output) ->
            return rej Error "Error in curl #code #output", null if code != 0
            res output

    with-cancel-and-dispose do
        execute-curl
        ->
            curl-process.kill! if !!curl-process
            returnP \killed

# default-document :: DataSourceCue -> String -> Document
export default-document = (data-source-cue, transpilation-language) ->
    query: """curl "https://api.github.com/emojis" """
    transformation: "JSON.parse"
    presentation: "json"
    parameters: ""
