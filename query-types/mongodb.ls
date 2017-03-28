{Promise, bind-p, from-error-value-callback, from-non-cancellable, new-promise,
return-p, reject-p, sequence-p, to-callback, with-cancel-and-dispose} = require \../async-ls
require! \./../config
{compile} = require \livescript
{MongoClient, ObjectID, Server} = require \mongodb
mongodbUri = require \mongodb-uri
EJSON = require \mongodb-extended-json

# prelude
{id, concat-map, dasherize, difference, each, filter, find, find-index, fold, foldr1, Obj, keys, map,
obj-to-pairs, pairs-to-obj, Str, unique, any, all, sort-by, floor, lines} = require \prelude-ls

{date-from-object-id, get-all-keys-recursively, object-id-from-date} = require \../public/lib/utils
{
    execute-javascript
    compile-and-execute
    compile-and-execute-babel
    compile-and-execute-livescript
    compile-and-execute-livescript-sync
} = require \transpilation
require! \csv-parse
require! \highland
require! \JSONStream

# parse-connection-string :: String -> DataSource
export parse-connection-string = (connection-string) ->
    [connection-string, collection] = connection-string.split '#'
    result = mongodb-uri.parse connection-string
    return {_parsed: true, collection: collection or null} <<< result
    # [, host, , port, database, collection]:result? = connection-string.match /mongodb\:\/\/([a-zA-Z0-9\.]+)(\:(\d+))?\/(.*)?\/(.*)?/
    # {host, port, database, collection}

# connections :: (CancellablePromise cp) => a -> cp b
export connections = (project, {connection-name, database}) -->

    # get-connections :: (CancellablePromise cp) => a -> cp Connections
    get-connections = ->
        res <- new-promise
        connections = (project.connections?.mongodb or {})
            |> obj-to-pairs
            |> map ([name, value]) -> {label: (value.label or name), value: name}
        res connections: connections

    # get-databases :: (Promise p) => String -> k p Databases
    get-databases = (connection-name) ->
        {host, port}:connection? = project.connections?.mongodb?[connection-name]
        return reject-p new Error "connection name: #{connection-name} not found in project" if !connection

        # return the database in the project, if the connection is a "database-connection"
        return return-p {connection-name, databases: [connection.database]} if !!connection?.database

        # return the list of all databases, if the connection is a "server-connection"
        databases <- bind-p execute-mongo-database-query-function do
            {host, port, database: \admin}
            (db) ->
                admin = db.admin!
                {databases} <- bind-p admin.list-databases!
                databases
                    |> map (.name)
                    |> return-p

        return-p do
            connection-name: connection-name
            databases: databases

    # get-collections :: (CancellablePromise cp) => String -> String -> cp Collections
    get-collections = (connection-name, database) -->
        {host, port}:connection? = project.connections?.mongodb?[connection-name]
        return reject-p new Error "connection name: #{connection-name} not found in project" if !connection

        collections <- bind-p execute-mongo-database-query-function do
            {host, port, database: connection?.database or database}
            (db) ->
                resolve, reject <- new-promise
                err, collections <- db.list-collections! .to-array
                if err
                    reject err
                else
                    collections
                        |> map ({name}) ->
                            if (name.index-of \.) == -1
                                name
                            else
                                name .split \. .1
                        |> resolve
            Math.floor Math.random! * 1000000

        return-p do
            connection-name: connection-name
            database: database
            collections: collections

    switch
        | !connection-name => get-connections!
        | !database => get-databases connection-name
        | _ => get-collections connection-name, database

# keywords :: (CancellablePromise cp) => [DataSource, String] -> cp [String]
export keywords = ([data-source]) ->
    # TODO: hardcoded collection name in data-source
    pipeline =
        * $sort: _id: -1
        * $limit: 10
    results <- bind-p execute-mongo-database-query-function do
        data-source
        (db) -> execute-aggregation-pipeline false, (db.collection data-source.collection || "analytics"), pipeline
        #pipeline
    collection-keywords = results
        |> concat-map (-> get-all-keys-recursively ((k, v)-> typeof v != \function), it)
        |> unique
    return-p do
        keywords: collection-keywords ++ (collection-keywords |> map -> "$#{it}") ++
        ((get-all-keys-recursively (-> true), get-context!) |> map dasherize) ++
        <[$add $add-to-set $all-elements-true $and $any-element-true $avg $cmp $concat $cond $day-of-month $day-of-week $day-of-year $divide
          $eq $first $geo-near $group $gt $gte $hour $if-null $last $let $limit $literal $lt $lte $map $match $max $meta $millisecond $min $minute $mod $month
          $multiply $ne $not $or $out $project $push $redact $second $set-difference $set-equals $set-intersection $set-is-subset $set-union $size $skip $sort
          $strcasecmp $substr $subtract $sum $to-lower $to-upper $unwind $week $year do]>

# convert-livescript-query-to-pipe-mongo-syntax :: String -> String
convert-livescript-query-to-pipe-mongo-syntax = (query) ->
    lines = (str) -> str.split '\n'
    "aggregate do \n" + ((foldr1 (+)) . (map (x) -> "    #{x}\n") . lines) query

# convert-babel-query-to-pipe-mongo-syntax :: String -> String
convert-babel-query-to-pipe-mongo-syntax = (query) ->
    # pending :: String?
    # tokens :: [String] a line starting with $ is the start of a token
    {pending, tokens} = query
        |> lines
        |> fold do
            ({pending, tokens}, a) ->
                if a.0 == '$'
                    if !!pending
                        tokens.push pending + ","
                    pending := a + \\n
                else
                    pending += a + \\n
                {pending, tokens}
            {pending: null, tokens: []}

    tokens.push pending
    tokens |> foldr1 (++)

# convert-query-to-pipe-mongo-syntax-and-execute :: String -> {} -> (String -> String) -> (String -> String) -> Promise [{}]:pipeline
convert-query-to-pipe-mongo-syntax-and-execute = (query, query-context, converter, transpiler) -->
    transpiler (converter query), query-context <<< {
        aggregate: (...args) -> args
    } <<<
        # mongodb aggregation pipeline operators from http://docs.mongodb.org/manual/reference/operator/aggregation/
        ["$project", "$match", "$redact", "$limit", "$skip", "$unwind", "$group", "$sort", "$geoNear", "$out", "$lookup"]
        |> map -> ["#it", (hash) -> "#it": hash]
        |> pairs-to-obj

# convert-query-to-livescript-array :: String -> String
convert-query-to-livescript-array = (query) ->
    lines = (str) -> str.split '\n'
    "json = \n"  + ((foldr1 (+)) . (map (x) -> "    #{x}\n") . lines) query

trim-livescript-code = (query) ->
    query.replace /(\/\*[\w\'\s\r\n\*]*\*\/)|(\#[\w\s\']*)/gmi, ''

trim-babel-code = (query) ->
    query.replace /(\/\*[\w\'\s\r\n\*]*\*\/)|(\/\/[\w\s\']*)/gmi, ''

# get-context :: a -> Context
export get-context = ->
    bucketize = (bucket-size, field) --> $divide: [$subtract: [field, $mod: [field, bucket-size]], bucket-size]
    # {date-from-object-id, object-id-from-date} = require \./../public/scripts/utils.ls
    {} <<< (require \./default-query-context.ls)! <<< {

        # dependent on mongo operations
        day-to-timestamp: (field) -> $multiply: [field, 86400000]
        timestamp-to-day: bucketize 86400000
        bucketize: bucketize
        object-id: (x) -> "$oid": (ObjectID x)
        object-id-from-date1: (x) -> (object-id-from-date x)

        # independent of any mongo operations
        date-from-object-id
        setImmediate
    }

# execute-aggregation-pipeline :: (Promise p) => Boolean -> MongoDBCollection -> AggregateQuery -> p result
execute-aggregation-pipeline = (allow-disk-use, collection, query) -->
    console.log(EJSON.stringify(query, null, 2))
    # query = EJSON.parse("""[{"$match":{"_id":{"$gt":{"$oid":"58c09b000000000000000000"}}}},{"$limit":100}]""")
    ((from-error-value-callback collection.aggregate, collection) query, {allow-disk-use})

# execute-aggregation-map-reduce :: (Promise p) => MongoDBCollection -> AggregateQuery -> p result
execute-aggregation-map-reduce = (collection, {$map, $reduce, $options, $finalize}:query) -->
    (from-error-value-callback collection.map-reduce, collection) do
        $map
        $reduce
        {} <<< $options <<< {finalize: $finalize}

# utility function for executing a single raw mongodb query
# mongo-database-query-function :: (db, callback) --> void;
# can also be used to perform db.****** functions
# execute-mongo-database-query-function :: (CancellablePromise cp) => DataSource -> (MongoDatabase -> p result) -> cp result
export execute-mongo-database-query-function = ({host, port, database}:parsed-connection-string, mongo-database-query-function) -->

    #TODO: get collection name
    connection-string = if !!parsed-connection-string._parsed then mongodb-uri.format(parsed-connection-string) else "mongodb://#{host}:#{port}/#{database}"

    # establish a connection to the server
    mongo-client = new MongoClient!

    mongo-client <- bind-p with-cancel-and-dispose do
        (from-error-value-callback mongo-client.connect, mongo-client) connection-string, { connectTimeoutMS: 1000 * 60 * 3, socketTimeoutMS: 1000 * 60 * 3 }
        -> return-p \killed-early

    # execute the query
    db = null
    start-time = null

    # dispose :: () -> ()
    dispose = !->
        db.close!
        mongo-client.close!

    # kill :: (CancellablePromise cp) => () -> cp kill-result
    cancel = ->
        if \connected == db.server-config?._server-state
            {inprog} <- bind-p (db.collection \$cmd.sys.inprog .find-one {})

            milliseconds-running = Date.now! - start-time

            op = inprog
                |> sort-by ({microsecs_running}) -> milliseconds-running - (microsecs_running / 1000)
                |> (.0)

            if op
                # same as (db.kill-op opid)
                db.collection \$cmd.sys.killop .find-one op: op.opid .then -> \killed

            else
                reject-p new Error "query could not be found\nStarted at: #{start-time}"

        else
            reject-p new Error "_server-state is not connected"

    # execute-query-function :: () -> p result
    execute-query-function = do ->
        db := mongo-client.db database
        start-time := new Date!.value-of!
        mongo-database-query-function db

    with-cancel-and-dispose execute-query-function, cancel, dispose

# for executing a single mongodb query POSTed from client
# execute :: (CancellablePromise cp) =>
#  TaskManager -> QueryStore -> DataSource -> String -> String -> CompiledQueryParameters -> cp result
export execute = (, , {collection, allow-disk-use}:data-source, query, transpilation-language, parameters) -->

    # aggregation-type :: String
    # computation :: (CancellablePromise cp) => () -> cp result
    [aggregation-type, computation] <- bind-p do ->
        res, rej <- new-promise
        query-context = {} <<< get-context! <<< (require \prelude-ls) <<< parameters
        {aggregation-type, computation} = switch

            # COMPUTATION: detect computation query-type by a directive
            | (query.index-of '#! computation') == 0 =>
                aggregation-type: \computation
                computation: ->

                    # remove the directive line
                    query-without-directive = query.substring (query.index-of '\n') + 1

                    # database-query-function :: MongoDatabase -> cp result
                    database-query-function <- bind-p compile-and-execute do

                        # code
                        match transpilation-language
                            | \javascript => "f = #{query-without-directive}"
                            | \babel => "f = #{query-without-directive}"
                            | _ => query-without-directive

                        # language
                        transpilation-language

                        # context
                        {} <<< query-context <<< {
                            Promise
                            bind-p
                            console
                            from-error-value-callback
                            new-promise
                            return-p
                            sequence-p
                        }
                    execute-mongo-database-query-function data-source, database-query-function

            # MAP REDUCE: detect by presence of $map, $reduce & options
            | (
                <[$map $reduce options]>
                    |> all (stage) -> (query.index-of stage) > -1
            ) =>
                aggregation-type: \map-reduce
                computation: ->

                    # map-reduce-query :: {$map :: a, $reduce :: a, $finalize :: a}
                    map-reduce-query <- bind-p compile-and-execute do
                        match transpilation-language
                            | 'javascript' => "json = #{query}"
                            | 'babel' => "{\n#{query}\n}"
                            | _ => "{\n#{query}\n}"
                        transpilation-language
                        query-context

                    result <- bind-p execute-mongo-database-query-function data-source, (db) ->
                        execute-aggregation-map-reduce (db.collection collection), map-reduce-query

                    return-p do
                        if !result.collection-name
                            result
                        else
                            result:
                                collection-name: result.collection-name
                                tag: result.db.tag

            # AGGREGATION PIPELINE
            | _ =>
                aggregation-type: 'pipeline'
                computation: ->
                    aggregation-query <- bind-p do
                        match transpilation-language
                        # using 'json = ...' converts query to an expression from JSON
                        | \javascript =>
                            trimmed-query = trim-babel-code query
                            if trimmed-query.0 == '['
                                execute-javascript ("json = #{query}"), query-context
                            else
                                convert-query-to-pipe-mongo-syntax-and-execute do
                                    query
                                    query-context
                                    convert-babel-query-to-pipe-mongo-syntax
                                    execute-javascript

                        | \babel =>
                            trimmed-query = trim-babel-code query
                            if trimmed-query.0 == '['
                                compile-and-execute-babel "{\n#{query}\n}", query-context
                            else
                                convert-query-to-pipe-mongo-syntax-and-execute do
                                    query
                                    query-context
                                    convert-babel-query-to-pipe-mongo-syntax
                                    compile-and-execute-babel

                        | \livescript =>
                            trimmed-query = trim-livescript-code query
                            if trimmed-query.0 == '['
                                compile-and-execute-livescript "\n#{query}\n", query-context
                            else if trimmed-query.0 == '*'
                                compile-and-execute-livescript do
                                    convert-query-to-livescript-array query
                                    query-context
                            else
                                convert-query-to-pipe-mongo-syntax-and-execute do
                                    query
                                    query-context
                                    convert-livescript-query-to-pipe-mongo-syntax
                                    from-non-cancellable compile-and-execute-livescript

                    console.log(JSON.stringify(aggregation-query))
                    console.log("---")
                    ejson-aggregation-query = EJSON.parse(JSON.stringify(aggregation-query))

                    execute-mongo-database-query-function do
                        data-source
                        (db) ->
                            #TODO: hardcoded for sam analytics
                            #TODO: we need to get the collection name in addition to query-string
                            execute-aggregation-pipeline allow-disk-use, (db.collection <| collection or \analytics), ejson-aggregation-query

        res [aggregation-type, computation]

    computation!


# default-document :: DataSourceCue -> String -> Document
export default-document = (data-source-cue, transpilation-language) ->
    query: switch transpilation-language
    | \livescript => """
        $sort _id: -1
        $limit 20
    """
    | _ => """
        [
            {
                $sort: {_id: -1}
            },
            {
                $limit: 20
            }
        ]
    """
    transformation: "id"
    presentation: "json"
    parameters: ""

import-json = (file, data-source) ->
    execute-mongo-database-query-function do
        data-source
        (db) ->
            resolve, reject <- new-promise
            collection = db.collection data-source.collection
            stream = JSONStream.parse "*"
            file.pipe stream
            i = 0
            buffer = []
            stream
                ..on \data, (data) ->
                    i := i + 1
                    buffer.push data
                    if 0 == (i % 100)
                        copy = buffer
                        buffer := []

                        stream.pause!

                        err, _ <- collection.insert copy, {w: 1}
                        if !!err
                            reject err
                            # stream.end!
                        else
                            stream.resume!

                ..on \error, (err) ->
                    console.log "JSON Stream Error", err
                    reject err
                    # stream.end!


                ..on \end, ->
                    copy = buffer
                    buffer := []

                    if copy.length > 0
                        err, _ <- collection.insert copy, {w: 1}
                        if !!err
                            reject err
                        else
                            resolve {inserted: i}
                    else
                        resolve {inserted: i}

export import-stream = (file, parser, data-source, response) ->

    execute-mongo-database-query-function do
        data-source
        (db) ->

            resolve, reject <- new-promise

            done = false


            collection = db.collection data-source.collection

            {ObjectID} = require \mongodb
            [err, transformationf] = compile-and-execute-livescript-sync parser, {JSONStream, highland, csv-parse, ObjectID} <<< (require \prelude-ls)
            reject err if !!err

            parse = transformationf

            # parse = csv-parse {comment: '#', relax: true, skip_empty_lines: true, trim: true, auto_parse: true, columns: true}

            file.pipe highland.pipeline (s) ->
                rs = s.pipe parse
                rs.on "error", (err) ->
                    console.log "file > parse error", err
                    <- set-timeout _, 500
                    return if done
                    done := true
                    reject err

                rs
                    .pipe highland.pipeline (s) -> s.batch 1024
                    .through do ->
                        tr = new require "stream" .Transform {objectMode: true}
                            .._transform = (chunk, enc, next) ->
                                return if done

                                err, res <~ collection.insert chunk, {w: 1}
                                if !!err
                                    @emit "error", err
                                else
                                    return if done
                                    @push chunk.length
                                    response.write "{\"written\": #{chunk.length}}\n"
                                    next!
                    .stopOnError (err) ->
                        console.log "stopOnError", err
                        done := true
                        reject err
                    .reduce1 (+)
                    .each (chunk) ->
                        return if done
                        process.stdout.write "#{chunk}\n"
                        resolve {inserted: chunk}
                    .done ->
                        done := true
