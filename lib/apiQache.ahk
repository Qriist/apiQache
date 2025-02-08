;#Include <SingleRecordSQL>
;#Include <LibCrypt>
; #Include %A_MyDocuments%\Autohotkey\Lib\v2\class_SQriLiteDB_modified.ahk
;#Include %A_MyDocuments%\Autohotkey\Lib\v2\Winhttp.ahk
;#Include <string_things>
class apiQache { 

	__New(optObj := Map()){
		; this.acDB := ""	;api cache DB
		this.acDir := ""	;api cache dir, used only for bulk downloads
		this.uncDB := ""
		this.acExpiry := 518400	;api cache expiry
								;how many seconds to wait before burning api call for fresh file
								;default = 518400 (6 days)
		; this.web := WinHttpRequest()
		this.outHeadersText := ""
		this.outHeadersMap := Map()
		this.preparedOutHeadersText := ""
		this.lastResponseHeaders := ""
		this.WinHttpRequest_encoding := "UTF-8"
		this.openTransaction := 0
		this.lastServedSource := "nothing"	;holds the string "server" if the class burned api, or "cache" otherwise.
		this.bulkRetObj := []
		this.preparedSQL := Map()
		this.compiledSQL := Map()

		;This instance will connect to any instance the main script has
		;If you need to set the DLL or SSL then init the LibQurl class prior to apiQache
		this.curl := LibQurl()

		;silos the apiQache connections into its own pool
		this.multi_handle := this.curl.MultiInit()
		this.easy_handle := this.curl.EasyInit()

		this.init(optObj)
	}

	init(optObj,&web?){
			
		; if (Type(curl) != "LibQurl")
		; 	curl := LibQurl(optObj["dllpat1h"])
		; msgbox this.web.PrintObj(this.web.easyHandleMap)
		; msgbox curl.GetVersionInfo()["brotli_ver_num"]
		; msgbox Type(curl)
		; this.initDir(optObj["pathToDir"])
		this.initDB(optObj["pathToDB"])
		this.initPreparedStatements()
		return
	}
	initDir(pathToDir){	;don't need anymore?
		DirCreate(pathToDir)
		this.acDir := Trim(pathToDir,"\")
	}
	initDB(pathToDB,journal_mode := "wal",synchronous := 0){	
		If FileExist(pathToDB){
			this.acDB :=  SQriLiteDB()
			if !this.acDB.openDB(pathToDB)
				msgbox("error opening database")
		}
		else{
			SplitPath(pathToDB,&FileName,&FileDir)
			DirCreate(FileDir)
			this.acDB :=  SQriLiteDB()
			this.acDB.openDB(pathToDB)
			ddlObj := this.initSchema()
			
			for k,v in ddlObj {
				
				if !this.acDB.exec(v)
					msgbox("error creating table in new database")
			}
		}
		this.acDB.exec("PRAGMA journal_mode=" journal_mode ";")
		this.acDB.exec("PRAGMA synchronous=" synchronous ";")
		
		
		;this.acDB.getTable("PRAGMA synchronous;",table)
		;msgbox % st_printArr(table)
		;this.acDB.exec("VACUUM;")
	}
	initSchema(){
		retObj := []
		ret := "
		(
		CREATE TABLE apiCache (
			--overhead
			fingerprint       TEXT PRIMARY KEY UNIQUE,
			timestamp         INTEGER,
			expiry            INTEGER,

			--identification
			url               TEXT,
			headers           TEXT,
			post              TEXT,
			mime              TEXT,
			request           TEXT,

			--results
			responseHeaders   BLOB,
			responseHeadersSz INTEGER,
			data              BLOB,
			dataSz            INTEGER
		`);
		)"
		retObj.push(ret)
		
		ret := "
		(
		CREATE INDEX fingerprint ON apiCache (
    		fingerprint ASC
		`);
		)"
		retObj.Push(ret)

		ret := "
		(
		CREATE VIEW vRecords AS
			SELECT fingerprint,
				timestamp,
				expiry,
				sqlar_uncompress(responseHeaders, responseHeadersSz) AS responseHeaders,
				sqlar_uncompress(data, dataSz) AS data
			FROM apiCache;
		)"
		retObj.push(ret)
		
		ret := "
		(
		CREATE VIEW vRecords_complete AS
			SELECT fingerprint,
				timestamp,
				expiry,
				url,
				headers,
				post,
				mime,
				request,
				sqlar_uncompress(responseHeaders, responseHeadersSz) AS responseHeaders,
				responseHeadersSz,
				sqlar_uncompress(data, dataSz) AS data,
				dataSz
			FROM apiCache;
		)"
		retObj.push(ret)
		
		return retObj		
	}
	initExpiry(expiry){
		this.acExpiry := expiry
	}
	initPreparedStatements(){
		this.preparedSQL["retrieve/server"] := "INSERT OR IGNORE INTO apiCache (fingerprint,timestamp,expiry,url,headers,post,mime,request,responseHeaders,responseHeadersSz,data,dataSz) "
			.	"VALUES (?1,?2,?3,?4,?5,?6,?7,?8,sqlar_compress(CAST(?9 AS BLOB)),LENGTH(CAST(?9 AS BLOB)),sqlar_compress(CAST(?10 AS BLOB)),LENGTH(CAST(?10 AS BLOB))) "
			.	"ON CONFLICT ( fingerprint ) "
			.	"DO UPDATE SET "
			.	"timestamp = excluded.timestamp,"
			.	"expiry = excluded.expiry,"
			.	"url = excluded.url,"
			.	"headers = excluded.headers,"
			.	"post = excluded.post,"
			.	"mime = excluded.mime,"
			.	"request = excluded.request,"
			.	"responseHeaders = excluded.responseHeaders,"
			.	"responseHeadersSz = excluded.responseHeadersSz,"
			.	"data = excluded.data,"
			.	"dataSz = excluded.dataSz;"

		
		this.preparedSQL["retrieve/cache"] := "SELECT sqlar_uncompress(data,dataSz) AS data, sqlar_uncompress(responseHeaders,responseHeadersSz) AS responseHeaders "
			.	"FROM apiCache "
			.	"WHERE fingerprint = ? "
			.	"AND expiry > ?;"
		
		this.preparedSQL["invalidateRecord"] := "UPDATE apiCache SET expiry = 0 WHERE fingerprint = ?;"
		; msgbox "UPDATE simpleCacheTable SET expiry = 0 WHERE fingerprint = '?';"
		for k,v in this.preparedSQL {
			st := ""
			this.acDB.Prepare(v,&st)
			this.compiledSQL[k] := st
		}
	}
	setHeaders(headersMap?){
		if !IsSet(headersMap)
			return this.outHeadersText := ""
		this.outHeadersMap := headersMap
		this.curl.SetHeaders(headersMap,this.easy_handle)
		this.outHeadersText := ""
		for k,v in headersMap {
			this.outHeadersText .= k ": " v "`n"
		}
	}
	setRequest(requestString?){
		if !IsSet(requestString) || (requestString = "GET")
			return this.outRequestString := ""
		this.curl.SetOpt("CUSTOMREQUEST",requestString,this.easy_handle)
		this.outRequestString := requestString
	}
	setPost(post?){
		If !IsSet(post)
			return this.outPostHash := ""
		;use curl to prepare the post data into a buffer
		this.curl.SetPost(post,this.easy_handle)
		this.outPostHash := this.hash(&p := this.curl.easyHandleMap[this.easy_handle]["postData"],"SHA512")
	}
	retrieve(url, headers?, post?, mime?, request?, expiry?, forceBurn?){
		table := ""
		chkCache := ""
		if !IsSet(expiry)
			expiry := this.acExpiry
		/*
			-check if url+header (fingerprint) exists in db
			-if url doesn't exist -> burn api
				
			-check expiry
			-if url too old -> burn api
				
			-if url (fingerprint) AND expiry is good AND fileblob exists -> return fileblob from db
				?-if file doesn't exist (which it should) -> burn api
		*/
		; msgbox  url
		this.setHeaders(headers?)
		this.setRequest(request?)
		this.setPost(post?)

		fingerprint := this.generateFingerprint(url
			,	(this.outHeadersText=""?unset:this.outHeadersText)
			,	(!IsSet(post)?unset:post)
			,	unset ;mime (this.outHeadersText=""?unset:this.outHeadersText)
			,	(this.outRequestString=""?unset:this.outRequestString)
			,	1)
		timestamp := expiry_timestamp := A_NowUTC	;makes the timestamp consistent across the method
		expiry_timestamp := DateAdd(expiry_timestamp, expiry, "seconds")
		;msgbox timestamp "`n" expiry_timestamp

		If !IsSet(forceBurn){	;skips useless db call if set
			SQL := "SELECT sqlar_uncompress(data,dataSz) AS data, sqlar_uncompress(responseHeaders,responseHeadersSz) AS responseHeaders "
				.	"FROM apiCache "
				.	"WHERE fingerprint = '" fingerprint "' "
				.	"AND expiry > " Min(timestamp,expiry_timestamp) ";"	;uses lower number between current and user-set timestamp
			If !this.acDB.getTable(sql,&table)	;finds data only if it hasn't expired
				msgbox A_Clipboard := "--expiry check failed under optional burn`n" sql
			
			If (table.RowCount > 0) {	;RowCount will = 0 if nothing found
				table.NextNamed(&chkCache)
				this.lastResponseHeaders := chkCache["responseHeaders"]
				this.lastServedSource := "cache"
				return chkCache["data"]	;returns previously cached data
			}
		}
		;msgbox fingerprint
		
		; WinHttpRequest(url, post, responseHeaders, options this.WinHttpRequest_encoding "`n" WinHttpRequest_windowsCache)
		;outHeadersMap["Accept-Encoding"] := "br, gzip, deflate, compress"	;add compression headers to request
		
		;msgbox outHeadersMap["Accept-Encoding"]
		; req := this.acWeb.request(url,(!IsSet(post)?'GET':'POST'),post?,outHeadersMap)
		this.curl.SetOpt("URL",url,this.easy_handle)
		this.curl.Sync(this.easy_handle)
		response := this.curl.GetLastBody(,this.easy_handle)

		this.lastResponseHeaders := this.curl.GetLastHeaders(,this.easy_handle)

		;Types := {Blob: 1, Double: 1, Int: 1, Int64: 1, Null: 1, Text: 1}
		insMap := Map(1,Map("Text",fingerprint)	;fingerprint
				,	2,Map("Int64",timestamp)	;timestamp
				,	3,Map("Int64",expiry_timestamp)	;expiry
				,	4,Map("Text",url)	;url
				,	5,Map((this.outHeadersText=""?"NULL":"Text"),(this.outHeadersText=""?"NULL":this.hashComponents["headers"]))	;headers
				,	6,Map((this.outPostHash=""?"NULL":"Text"),(this.outPostHash=""?"NULL":this.hashComponents["post"]))	;post
				,	7,Map("NULL","")	;mime
				,	8,Map((this.outRequestString=""?"NULL":"Text"),(this.outRequestString=""?"NULL":this.hashComponents["request"]))	;request
				,	9,Map("Text",this.lastResponseHeaders)	;responseHeaders
				,	10,Map("Text",response))	;data
		
		this.compiledSQL["retrieve/server"].Bind(insMap)
		this.compiledSQL["retrieve/server"].Step()
		this.compiledSQL["retrieve/server"].Reset()
		this.lastServedSource := "server"

		return response := this.curl.GetLastBody(,this.easy_handle)
	}
	/*	bulk insert stuff
			
		
		buildBulkRetrieve(url,headers := "",expiry := "",forceBurn := 0){
		;queues one fingerprint for .bulkRetrieve()
			if (expiry = "")
				expiry := this.acExpiry
			
			fingerprintObj := {"url":url,"forceBurn":forceBurn,"expiry":expiry,"options":{"headers":headers,"gid":format("{1:016X}",this.bulkRetObj.count()+1),"dir":this.acDir,"out":this.generateFingerprint(url,headers)}}
			this.bulkRetObj.push(fingerprintObj)
		}
		bulkRetrieve(maxConcurrentDownloads := 5, urlObj := ""){
			if (urlObj = "")
				urlObj := this.bulkRetObj
		;msgbox % st_printArr(urlObj)
			cuidFingerprintMap := []
			mapIndex := 0
			retFingerprints := []
		;msgbox % this.acDir "\bulk.txt"
			bulk := FileOpen(this.acDir "\bulk.txt","w")
			for k,v in urlObj{
			;check if the fingerprint's cache is expired
			;fingerprint := this.generateFingerprint(v["url"],v["options","headers"])	
				fingerprint := v["options","out"]
				
				timestamp := expiry_timestamp := A_NowUTC	;makes the timestamp consistent across the method
				EnvAdd,expiry_timestamp, % v["expiry"], Seconds	
				
				If (v["forceBurn"] = 0){	;skips unneeded db call if !0
				;not pulling data at this stage so we don't need blobs
					SQL := "SELECT fingerprint FROM simpleCacheTable WHERE fingerprint = '" fingerprint "' AND expiry > " Min(timestamp,expiry_timestamp) ";"	;uses lower number between current and user-set timestamp
					If !this.acDB.getTable(sql,table)	;finds data only if it hasn't expired
						msgbox % clipboard := "--expiry check failed under optional burn`n" sql
				;msgbox % clipboard := sql
				;msgbox % st_printArr(table)
					If (table.RowCount > 0) {	;RowCount will = 0 if nothing found
					;add to the list of fingerprints
						retFingerprints[fingerprint] := {"url":v["url"],"headers":v["options","headers"],"source":"cache"}
						continue	;will use cached data so nothing to do
					}
				}
			;msgbox % "yo"
				bulk.write(this.formatAria2cUrl(v["url"],v["options"]) "`n")
				mapIndex += 1
				cuidFingerprintMap[mapIndex] := {"fingerprint":fingerprint,"url":v["url"],"headers":v["options","headers"]}	;assuming the .count() = aria2c's CUID
			}
			bulk.close()
		;msgbox % "test"
			if !(FileGetSize(this.acDir "\bulk.txt") > 20)	;file is definitely too small
				return retFingerprints	;all files were found in cache
			
		;actually download the bulk items
		;aria2c -i out.txt --http-accept-gzip true --max-concurrent-downloads=30 --console-log-level=notice  --log=log.txt
			FileDelete, % this.acDir "\bulk.log"
			runLine := chr(34) A_ScriptDir "\aria2c.exe"	chr(34) a_space
			.	"-i " chr(34) this.acDir "\bulk.txt" chr(34) a_space
			.	"--http-accept-gzip true" a_space
			.	"--http-no-cache" a_space
			.	"--max-concurrent-downloads=" maxConcurrentDownloads a_space
			.	"--allow-overwrite" a_space
			.	"--log-level=info" a_space
			.	"--disk-cache=250M" a_space
			.	"--deferred-input true" a_space
			.	"--log=" chr(34) this.acDir "\bulk.log" chr(34)
		;msgbox % clipboard := runLine
			RunWait, % runLine
			
		;parse the log for responseHeaders
			static needle := "mUs)\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ \[INFO] \[HttpConnection.+] CUID#(\d+) - Response received:\r?\n(.+)\r?\n\r?\n"
			parseLog := RegExMatchGlobal(FileOpen(this.acDir "\bulk.log","r").read(),needle,0)
		;msgbox % st_printArr(parseLog)
			
			for k,v in parseLog {
				cuid := v[1] + 6
				fingerprint := cuidFingerprintMap[cuid,"fingerprint"]
				if (fingerprint = ""){
				;msgbox % st_printArr(v) st_printArr(cuidFingerprintMap)
					
				}
			;msgbox % 
				quotedResponseHeaders := sqlQuote(v[2])
				insObj := {"url":cuidFingerprintMap[cuid,"url"]
				,"headers":cuidFingerprintMap[cuid,"headers"]
				,"responseHeaders":"sqlar_compress(CAST(" quotedResponseHeaders " AS BLOB))"	
				,"responseHeadersSz":"length(CAST(" quotedResponseHeaders " AS BLOB))"
				;,"responseHeadersSz":StrPut(responseHeaders, "UTF-8")
				,"fingerprint":fingerprint
				,"timestamp":timestamp
				,"expiry":expiry_timestamp
				,"mode":"777"
				,"dataSz":FileGetSize(this.acDir "\" fingerprint)
				;,"dataSz":StrPut(post, "UTF-8")
				,"data":"sqlar_compress(READFILE(" sqlQuote(this.acDir "\" fingerprint) "))"}	 
				
			;SQL := SingleRecordSQL("simpleCacheTable",insObj,"fingerprint",,"responseHeaders,data")
				SQL := SingleRecordSQL("simpleCacheTable",insObj,"fingerprint",,"responseHeaders,responseHeadersSz,data,dataSz")
				
				
			;if (this.openTransaction = 0)
				;this.acDB.exec("BEGIN TRANSACTION;")
			;msgbox % clipboard := sql
				if !this.acDB.exec(sql)
					msgbox % clipboard := "--insObj failure`n" sql
				FileDelete, % this.acDir "\" fingerprint
			;if (this.openTransaction = 0)				
				;If !this.acDB.exec("COMMIT;")
					;msgbox % "commit failure"
				this.lastServedSource := "server"
			;msgbox % st_printArr(v)
			}
			
			
		;import into the db
		;return retFingerprints
		}
		formatAria2cUrl(url,options := ""){
			for k,v in options {
				switch k {
					case "headers" :{
						for k,v in StrSplit(options["headers"],"`n","`r"){
							if (v != "")
								opts .= "`n" a_tab "header=" v
						}
					}
					default : {
						if (v != "")
							opts .= "`n" a_tab k "=" v
					}
				}
			}
			return url opts
		}
	*/
	findRecords(urlToMatch := "",  dataToMatch := "", headersToMatch := "", responseHeadersToMatch := "",urlPartialMatch := 0){
		;looking for any records which match the parameters
		;blank parameters will not be considered
		;url is exact unless urlPartialMatch != 0, others will always look for partial matches
		;will return a Map object with [fingerprint,url,headers] fields to help prevent memory overflow

		SQL := "SELECT fingerprint,url,headers from vRecords WHERE "
		.	(urlToMatch!=""?(urlPartialMatch=0?"url = " this.sqlQuote(urlToMatch) :"INSTR(url," this.sqlQuote(urlToMatch) ")"):"url IS NOT NULL")	;more complicated logic at url to simplify the next three
		.	(dataToMatch!=""?" AND INSTR(data," this.sqlQuote(dataToMatch) ")":"")
		.	(headersToMatch=""?"":" AND INSTR(headers," this.sqlQuote(headersToMatch) ")")	;probably less likely to search headers so the null string is first match
		.	(responseHeadersToMatch=""?"":" AND INSTR(responseHeaders," this.sqlQuote(responseHeadersToMatch) ")")	;same as above
		.	";"
		; msgbox A_Clipboard := sql
		table := ""
		if !this.acDB.gettable(SQL,&table)
			msgbox a_clipboard "--Failure in findRecords`n" SQL
		retObj := Map()
		nextObj := Map()
		loop table.rowCount {
			table.nextNamed(&nextObj)
			retObj.push(nextObj)
		}
		return retObj
	}
	; fetchRecords(recordObj){
	; 	;accepts a linear array of fingerprints to return any number of rows
	; }
	; findAndFetchRecords(){	;find and fetch records in one step
	; 	;TODO
	; }
	generateFingerprint(url, headers?, post?, mime?, request?, internal?){
		;returns a concatonated hash of the outgoing url+headers+post+mime+request
		;fingerprint character length varies based on the # of set parameters
		
		hashComponents := Map()
		hashComponents["url"] := u := this.hash(&url,"SHA512")

		;todo - implement type detection
		If IsSetRef(&headers)
			hashComponents["headers"] := h := this.hash(&headers,"SHA512")
		; switch Type(post) {
		; 	case :
				
		; 	default:
				
		; }
		if IsSetRef(&post) {
			If IsSet(internal)
				hashComponents["post"] := p := this.curl.easyHandleMap[this.easy_handle]["postData"]
			else
				hashComponents["post"] := p := this.hash(&post,"SHA512")
		}

		; IsSetRef(&mime)
			; this.hashComponents["mime"] := m := 
		; switch Type(mime) {
		; 	case :
				
		; 	default:
				
		; }

		If IsSetRef(&request)
			hashComponents["request"] := r := this.hash(&request,"SHA512")

		If IsSet(internal)
			this.hashComponents := hashComponents

		return u
			.	(!IsSet(h)?"":"h" h)
			.	(!IsSet(p)?"":"p" p)
			.	(!IsSet(m)?"":"m" m)
			.	(!IsSet(r)?"":"r" r)
	}
	sqlQuote(input){
		return "'" (!InStr(input,"'")?input:StrReplace(input,"'","''")) "'"
	}
	invalidateRecords(recordArr){
		;accepts a linear array of fingerprints to forcefully stale any number of records
		;this does NOT delete the records, it sets the expiry to 0
		;useful when there's a known list of updated fingerprints
		
		if (this.openTransaction = 0)	;makes sure the user hasn't manually opened a transaction
			this.begin()
		for k,v in recordArr
			this.invalidateRecord(v)
		if (this.openTransaction = 1)
			this.commit()
	}
	invalidateRecord(fingerprint){
		;this does NOT delete the records, it sets the expiry to 0
		finMap := Map(1,Map("Text",fingerprint))
		this.compiledSQL["invalidateRecord"].Bind(finMap)
		,this.compiledSQL["invalidateRecord"].Step()
		,this.compiledSQL["invalidateRecord"].Reset()
	}
	; purge(url,header := "", partialHeaderMatch := 1){	;accepts an array of urls + headers to remove from the db+disk
		
	; 	loop, % urlobj.count(){
	; 		this.acDB.getNamedTable("SELECT diskId from cacheTable where url = '" urlObj[a_index] "';",table)
	; 		Loop, % table["rows"].count(){
	; 			table.next(out)
	; 			FileDelete, % this.acDir "\" out["diskId"]
	; 		}
	; 		this.acDB.exec("DELETE FROM cacheTable WHERE url = '" urlObj[a_index] "';")
	; 	}
	; }
	; massPurge(urlObj){
	; 	;TODO
	; }
	nuke(reallyNuke := 0){	;you didn't really like this db, did you?
		if (reallyNuke != 1)
			return
		this.acDB.exec("DELETE FROM apiCache;")
	}
	CloseDB(){
		this.acDB.exec("PRAGMA optimize;")
		return this.acDb.CloseDB()
	}
	exportUncompressedDb(pathToUncompressedDB,overwrite := 0,journal_mode := "wal"){
		;create a db that can be used by any version of SQLite
		if FileExist(pathToUncompressedDB){
			if (overwrite!=1)
				return
			else
				FileDelete pathToUncompressedDB
		}
		this.uncDB := SQriLiteDB()
		this.uncDB.openDB(pathToUncompressedDB)
		uncObj := []
		unc := "
		(
		CREATE TABLE apiCache (
			fingerprint       TEXT    PRIMARY KEY
									UNIQUE,
			timestamp         INTEGER,
			expiry            INTEGER,
			url               TEXT,
			headers           TEXT,
			post              TEXT,
			mime              TEXT,
			request           TEXT,
			responseHeaders   BLOB,
			responseHeadersSz INTEGER,
			data              BLOB,
			dataSz            INTEGER
		`);
		)"
		uncObj.push(unc)
		
		unc := "
		(
		CREATE VIEW vRecords AS
			SELECT fingerprint,
				timestamp,
				expiry,
				sqlar_uncompress(responseHeaders, responseHeadersSz) AS responseHeaders,
				sqlar_uncompress(data, dataSz) AS data
			FROM apiCache;
		)"
		uncObj.push(unc)
		
		unc := " 
		(
		CREATE VIEW vRecords_complete AS
			SELECT fingerprint,
				timestamp,
				expiry,
				url,
				headers,
				post,
				mime,
				request,
				sqlar_uncompress(responseHeaders, responseHeadersSz) AS responseHeaders,
				responseHeadersSz,
				sqlar_uncompress(data, dataSz) AS data,
				dataSz
			FROM apiCache;
		)"
		uncObj.push(unc)
		if (overwrite!=0)
			for k,v in uncObj {
				tableDDL := v
				If !this.uncDB.exec(tableDDL)
					msgbox "--Error creating table in uncompressed DB`n" tableDDL
			}
		this.uncDB.exec("PRAGMA journal_mode=" journal_mode ";")			
		;this.uncDB.exec("VACUUM;")		
		this.uncDB.CloseDB()
		
		this.acDB.AttachDB(pathToUncompressedDB, "unc")
		SQL := "INSERT OR IGNORE INTO unc.apiCache SELECT * FROM main.vRecords_Complete;"
		this.acDB.exec(SQL)
		this.acDB.DetachDB("unc")
	}
	begin(){
		if (this.openTransaction = 1)	;can't open a new statement
			return
		;this.acDB.exec("PRAGMA locking_mode = EXCLUSIVE;")
		this.acDB.exec("BEGIN TRANSACTION;")
		this.openTransaction := 1
	}
	commit(){
		if (this.openTransaction = 0)	;nothing to commit
			return
		this.acDB.exec("COMMIT;")
		;this.acDB.exec("PRAGMA locking_mode = NORMAL;")
		this.openTransaction := 0
	}

	hash(&item:="", hashType:="", c_size:="", cb:="") { ; default hashType = SHA256 /// default enc = UTF-16
		Static _hLib:=DllCall("LoadLibrary","Str","bcrypt.dll","UPtr"), LType:="SHA256", LItem:="", LBuf:="", LSize:="", d_LSize:=1024000
		Static n:={hAlg:0,hHash:0,size:0,obj:""}
			 , o := {md2:n.Clone(),md4:n.Clone(),md5:n.Clone(),sha1:n.Clone(),sha256:n.Clone(),sha384:n.Clone(),sha512:n.Clone()}
		_file:="", LType:=(hashType?StrUpper(hashType):LType), LItem:=(item?item:LItem), ((!o.%LType%.hAlg)?make_obj():"")

		If (!item && !hashType) { ; Free buffers/memory and release objects.
			return !graceful_exit()
		} Else If (Type(LItem) = "String" && FileExist(LItem)) { ; Determine buffer type.
			_file := FileOpen(LItem,"r"), LBuf := true, LSize:=(c_size?c_size:d_LSize)
		} Else If (Type(item) = "String") || (Type(item) = "Integer") {
			LBuf := Buffer(StrPut(item,"UTF-8")-1,0), LItem:="", LSize:=d_LSize
			temp_buf := Buffer(LBuf.size+1,0), StrPut(item, temp_buf, "UTF-8"), copy_str()
		} Else If (Type(item) = "Buffer")
			LBuf := item, LItem:="", LSize:=d_LSize

		If (LBuf && !(outVal:="")) {
			hDigest := Buffer(o.%LType%.size) ; Create new digest obj
			Loop t:=(!_file ? 1 : (_file.Length//LSize)+1)
				(_file?_file.RawRead(LBuf:=Buffer(((_len:=_file.Length-_file.Pos)<LSize)?_len:LSize,0)):"")
			  , r7 := DllCall("bcrypt\BCryptHashData","UPtr",o.%LType%.obj.ptr,"UPtr",LBuf.ptr,"UInt",LBuf.size,"UInt",0)
			  , ((Type(cb)="Func") ? cb(A_index/t) : "")
			r8 := DllCall("bcrypt\BCryptFinishHash","UPtr",o.%LType%.obj.ptr,"UPtr",hDigest.ptr,"UInt",hDigest.size,"UInt",0)
			Loop hDigest.size ; convert hDigest to hex string
				outVal .= Format("{:02X}",NumGet(hDigest,A_Index-1,"UChar"))
		}
		
		_file?(_file.Close(),LBuf:=""):""
		return outVal
		
		make_obj() { ; create hash object
			r1 := DllCall("bcrypt\BCryptOpenAlgorithmProvider","UPtr*",&hAlg:=0,"Str",LType,"UPtr",0,"UInt",0x20) ; BCRYPT_HASH_REUSABLE_FLAG = 0x20
			
			r3 := DllCall("bcrypt\BCryptGetProperty","UPtr",hAlg,"Str","ObjectLength"
							  ,"UInt*",&objSize:=0,"UInt",4,"UInt*",&_size:=0,"UInt",0) ; Just use UInt* for bSize, and ignore _size.
			
			r4 := DllCall("bcrypt\BCryptGetProperty","UPtr",hAlg,"Str","HashDigestLength"
							   ,"UInt*",&hashSize:=0,"UInt",4,"UInt*",&_size:=0,"UInt",0), obj:= Buffer(objSize)
			
			r5 := DllCall("bcrypt\BCryptCreateHash","UPtr",hAlg,"UPtr*",&hHash:=0       ; Setup fast reusage of hash obj...
						 ,"UPtr",obj.ptr,"UInt",obj.size,"UPtr",0,"UInt",0,"UInt",0x20) ; ... with 0x20 flag.
			
			o.%LType% := {obj:obj, hHash:hHash, hAlg:hAlg, size:hashSize}
		}
		
		graceful_exit(r1:=0, r2:=0) {
			For name, obj in o.OwnProps() {
				If o.%name%.hHash && (r1 := DllCall("bcrypt\BCryptDestroyHash","UPtr",o.%name%.hHash)
								  ||  r2 := DllCall("bcrypt\BCryptCloseAlgorithmProvider","UPtr",o.%name%.hAlg,"UInt",0))
					throw Error("Unable to destroy hash object.")
				o.%name%.hHash := o.%name%.hAlg := o.%name%.size := 0, o.%name%.obj := ""
			} LBuf := "", LItem := "", LSize := c_size
		}
		
		copy_str() => DllCall("NtDll\RtlCopyMemory","UPtr",LBuf.ptr,"UPtr",temp_buf.ptr,"UPtr",LBuf.size)
	}
}