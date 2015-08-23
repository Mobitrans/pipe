{create-factory, DOM:{div, h1, table, input, form, button}}:React = require \react
AceEditor = require \./AceEditor.ls
DataSourceCuePopup = create-factory require \./DataSourceCuePopup.ls
{filter, map} = require \prelude-ls
$ = require \jquery-browserify
client-storage = require \../client-storage.ls
{is-equal-to-object} = require \../utils.ls

save-to-client-storage = (state) ->
    client-storage.save-document "import-data-source-cue", state.data-source-cue
load-from-client-storage = (state) ->
    if !state.data-source-cue
        state.data-source-cue = (client-storage.get-document "import-data-source-cue") ? {query-type: \mongodb, kind: \partial-data-source, complete: false}
    state

module.exports = React.create-class {

    display-name: \ImportRoute

    render: ->

        div {class-name: "import-route #{@state.state}"},
            h1 {}, "Import"

            div {
                style: 
                    position: \relative
                    height: \250px
            },
                DataSourceCuePopup do
                    left: -> 0
                    data-source-cue: @state.data-source-cue
                    on-change: (data-source-cue) ~> 
                        <~ @set-state {data-source-cue}
                        save-to-client-storage @state
            form {},
                input {
                    type: \file
                    on-change: (e) ~>
                        @set-state {file: e.target.files[0]}
                }, null
                button {
                    type: \submit
                    disabled: "uploading" == @state.state
                    on-click: (e) ~>
                        form-data = new FormData!

                        {file, data-source-cue} = @state

                        if !!file 

                            doc = 
                                document:
                                    data-source-cue: data-source-cue

                            form-data.append "doc", JSON.stringify doc
                            form-data.append "file", file

                            @set-state {state: "uploading"}
                            xhr = new XMLHttpRequest!
                                ..open 'POST', "/apis/queryTypes/mongodb/import", true
                                ..onload = (e) ~>
                                    switch 
                                    | 200 == xhr.status =>
                                        @set-state {state: "uploaded", message: xhr.responseText}
                                        console.log "done", xhr.responseText
                                    | otherwise =>
                                        @set-state {state: "error", message: xhr.responseText}
                                        console.log "error", xhr.responseText
                                    
                                ..onerror = (e) ~>
                                    @set-state {state: "error", message: "Unhandled error"}
                                    console.log "error", e
                                    
                                ..send form-data
                        else
                            # TODO: show an error
                            @set-state {state: "error", message: "Please select a file"}


                        e.stop-propagation!
                        e.prevent-default!
                }, "Upload!"
            div {class-name: "message"}, @state.message

            


        
    component-did-mount: -> 
        console.log @.props

    get-initial-state: -> 
        load-from-client-storage {
            state: "initial" # | uploading | uploaded | error
            message: null
            data-source-cue: null
            file: null
        }

}