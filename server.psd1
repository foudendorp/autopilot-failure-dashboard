@{
    # Pode server configuration. BodySize caps request bodies (diagnostics uploads) at the
    # transport level; the app additionally enforces maxUploadMB from config\settings.json.
    Server = @{
        Request = @{
            Timeout  = 600
            BodySize = 314572800   # 300 MB
        }
    }
}
