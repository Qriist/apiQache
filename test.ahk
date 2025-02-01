#Include <Aris/packages>
#Include %a_scriptdir%/lib/apiQache.ahk
dllpath := A_ScriptDir "\lib\Aris\Qriist\LibQurl@v0.90.0\bin\libcurl.dll"

curl := ""
; curl := LibQurl()
; msgbox
optObj := Map()
; optObj["dllpath"] := dllpath

api := apiQache(optObj,&curl)
curl.SetOpt("URL","https://www.google.com")
curl.sync()
msgbox curl.GetLastBody()
; api.init(A_ScriptDir,A_ScriptDir "\test.db")
; msgbox api.retrieve("https://www.google.com")
ExitApp
/*
db.exec("BEGIN TRANSACTION;")



prep := "INSERT OR IGNORE INTO simpleCacheTable (data,dataSz,fingerprint) "
    .	"VALUES (sqlar_compress(CAST(?1 AS BLOB)),LENGTH(CAST(?1 AS BLOB)),?2) "
    .	"ON CONFLICT ( fingerprint ) "
    .	"DO UPDATE SET "
    .	"data = excluded.data,"
    .	"dataSz = excluded.dataSz;"

db.Prepare(prep,&st)

fingerprint := "abc"
response := "xyz "
loop 1000
    response .= a_index

insMap := Map(1,Map("Text",  response)	;data
; ,	2,Map("Text", response)	;dataSz            <= no longer sent
,	2,Map("Text", fingerprint))	;fingerprint

st.Bind(insMap)
st.Step()
st.Reset()



db.exec("COMMIT;")



; --overhead
; fingerprint       TEXT PRIMARY KEY UNIQUE,
; timestamp         INTEGER,
; expiry            INTEGER,
; --identification
; url               TEXT,
; headers           TEXT,
; post              TEXT,
; mime              TEXT,
; -results
; responseHeaders   BLOB,
; responseHeadersSz INTEGER,
; data              BLOB,
; dataSz            INTEGER