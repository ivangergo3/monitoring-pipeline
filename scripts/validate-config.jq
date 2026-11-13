# Validate before IDs become filenames or values are passed to curl.
if type == "object"
  and ((.title // "Application health") | type == "string")
  and (.applications | type == "array" and length >= 1 and length <= 256)
  and ([.applications[].id] | length == (unique | length))
  and all(.applications[];
    type == "object"
    and (.id | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.name | type == "string" and test("\\S"))
    and (.url | type == "string" and test("^https?://[^/?#\\s@]+([/?#][^\\s]*)?$"))
    and ((.expected_status // 200) | type == "number" and floor == . and . >= 100 and . <= 599)
    and ((.timeout_seconds // 10) | type == "number" and . > 0 and . <= 60))
then .
else error("Invalid app config: provide 1–256 apps with unique safe IDs, names, public HTTP(S) URLs without credentials, HTTP status codes, and timeouts greater than 0 and at most 60 seconds")
end
