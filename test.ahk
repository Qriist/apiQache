﻿#Requires AutoHotkey v2.0 
#Include <Aris/packages>
#Include %a_scriptdir%/lib/apiQache.ahk


optObj := Map()
optObj["pathToDB"] := A_ScriptDir "\test.db"


api := apiQache(optObj)

; api.retrieve("https://www.google.com",,,,"https://www.google.com")
; api.retrieve("https://www.google.com",Map("?a","c"),1)
retobj := api.findRecords(,,,,,"999")
; api.retrieve("https://www.google.com",Map("a","c"),"1")
; msgbox JSON.dump(retobj)
A_Clipboard := JSON.Dump(api.fetchRecords(retobj))
ExitApp
testFile := FileOpen(A_ScriptDir "\sqlite3.dll","r")

headers := Map("test","cake")

fileObj := FileOpen(A_ScriptDir "\icuuc76.dll","r")
fileObj := FileOpen(A_ScriptDir "\icutu76.dll","r")
; msgbox api.generateFingerprint("1",,&p := "post")
; ExitApp
loop 10000
    api.retrieve("https://www.google.com/search?q=" a_index)

; api.exportUncompressedDb(A_ScriptDir "\uncompressed.db",1)
; api.retrieve("https://www.google.com",,"test",,"PATCH")
; msgbox api.web.PrintObj(api.web.GetVersionInfo())
; curl.SetOpt("URL","https://www.google.com")
; curl.sync()
; msgbox A_Clipboard := curl.GetLastHeaders() ;curl.GetLastBody()
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