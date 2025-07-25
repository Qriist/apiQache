﻿#Include <Aris\Qriist\LibQurl>
class apiQache { 
	__New(optObj := Map()){
		this.uncDB := ""
		this.acExpiry := 518400	;api cache expiry
								;how many seconds to wait before burning api call for fresh file
								;default = 518400 (6 days)

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
		this.optimizeAfterXInserts := 10000
		this.optimizeCounter := 0
		this.deferredOptimize := 0
		this.interval := 0
		this.lastRequestTimestamp := 0
		this.serverResponseNotSavedInDB := 0
		try this.magicFlushThreshold := optObj["magicFlushThreshold"]
		this.magicFlushThreshold ??= (1024 ** 2 * 50)	;50mb, matching LibQurl's default
		this.SQLITE_MAX_LENGTH := (1024 ** 2 * 950)	;950mb, a little under SqlarMultipleCipher's max row size

		;This instance will connect to any instance the main script has
		;If you need to set the DLL or SSL then init the LibQurl class prior to apiQache
		this.curl := LibQurl()

		;silos the apiQache connections into their own pool
		this.multi_handle := this.curl.MultiInit()
		this.easy_handle := this.curl.EasyInit()
		this.curl.WriteToMagic(this.magicFlushThreshold,this.easy_handle)

		this.initDB(optObj["pathToDB"]?)
		this.initPreparedStatements()
	}

	initDB(pathToDB?,journal_mode := "wal",synchronous := 0){
		pathToDB ??= A_ScriptDir "\cache\" StrReplace(A_ScriptName,".ahk") ".db"
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
			this.acDB.exec("PRAGMA optimize;")
		}
		this.acDB.exec("PRAGMA journal_mode=" journal_mode ";")
		this.acDB.exec("PRAGMA synchronous=" synchronous ";")
		
		
		;this.acDB.getTable("PRAGMA synchronous;",table)
		;msgbox % st_printArr(table)
		;this.acDB.exec("VACUUM;")
		OnExit (*) => this._cleanup()
	}
	initSchema(){
		retObj := []
		ret := "
		(
		CREATE TABLE apiQache (
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
			statusCode	      INTEGER,
			responseHeaders   BLOB,
			responseHeadersSz INTEGER,
			data              BLOB,
			dataSz            INTEGER
		`);
		)"
		retObj.push(ret)
		
		ret := "
		(
		CREATE INDEX fingerprint ON apiQache (
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
				statusCode,
				sqlar_uncompress(responseHeaders, responseHeadersSz) AS responseHeaders,
				sqlar_uncompress(data, dataSz) AS data
			FROM apiQache;
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
				statusCode,
				sqlar_uncompress(responseHeaders, responseHeadersSz) AS responseHeaders,
				responseHeadersSz,
				sqlar_uncompress(data, dataSz) AS data,
				dataSz
			FROM apiQache;
		)"
		retObj.push(ret)
		
		return retObj		
	}
	initExpiry(expiry){
		this.acExpiry := expiry
	}
	initPreparedStatements(){
		this.preparedSQL["retrieve/server"] := "INSERT OR IGNORE INTO apiQache (fingerprint,timestamp,expiry,url,headers,post,mime,request,statusCode,responseHeaders,responseHeadersSz,data,dataSz) "
			.	"VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,sqlar_compress(CAST(?10 AS BLOB)),LENGTH(CAST(?10 AS BLOB)),sqlar_compress(CAST(?11 AS BLOB)),LENGTH(CAST(?11 AS BLOB))) "
			.	"ON CONFLICT ( fingerprint ) "
			.	"DO UPDATE SET "
			.	"timestamp = excluded.timestamp,"
			.	"expiry = excluded.expiry,"
			.	"url = excluded.url,"
			.	"headers = excluded.headers,"
			.	"post = excluded.post,"
			.	"mime = excluded.mime,"
			.	"request = excluded.request,"
			.	"statusCode = excluded.statusCode,"
			.	"responseHeaders = excluded.responseHeaders,"
			.	"responseHeadersSz = excluded.responseHeadersSz,"
			.	"data = excluded.data,"
			.	"dataSz = excluded.dataSz;"

		
		this.preparedSQL["retrieve/cache"] := "SELECT CAST(sqlar_uncompress(data,dataSz) AS TEXT) AS data, sqlar_uncompress(responseHeaders,responseHeadersSz) AS responseHeaders, statusCode "
			.	"FROM apiQache "
			.	"WHERE fingerprint = ? "
			.	"AND expiry > ?;"
		
		this.preparedSQL["retrieve/asset"] := "SELECT sqlar_uncompress(data,dataSz) AS data, sqlar_uncompress(responseHeaders,responseHeadersSz) AS responseHeaders, statusCode "
			.	"FROM apiQache "
			.	"WHERE fingerprint = ? "
			.	"AND expiry > ?;"

		this.preparedSQL["invalidateRecord"] := "UPDATE apiQache SET expiry = 0 WHERE fingerprint = ?;"
		; msgbox "UPDATE simpleCacheTable SET expiry = 0 WHERE fingerprint = '?';"
		for k,v in this.preparedSQL {
			st := ""
			this.acDB.Prepare(v,&st)
			this.compiledSQL[k] := st
		}
	}
	setHeaders(headersMap?,easy_handle?){
		easy_handle ??= this.easy_handle
		if !IsSet(headersMap)
		&& !IsSet(easy_handle)	;only return on non-bulk
			return this.outHeadersText := ""
		this.outHeadersMap := headersMap ??= Map()
		this.curl.SetHeaders(headersMap,easy_handle)
		this.outHeadersText := ""
		for k,v in headersMap {
			this.outHeadersText .= k ": " v "`n"
		}
	}
	setRequest(requestString?,easy_handle?){
		if (!IsSet(requestString) || (requestString = "GET"))
		&& !IsSet(easy_handle)	;only return on non-bulk
			return this.outRequestString := ""
		easy_handle ??= this.easy_handle
		this.curl.SetOpt("CUSTOMREQUEST",requestString,easy_handle)
		this.outRequestString := requestString
	}
	setPost(post?,easy_handle?){
		If !IsSet(post)
		&& !IsSet(easy_handle)	;only return on non-bulk
			return this.outPostHash := ""
		easy_handle ??= this.easy_handle
		;use curl to prepare the post data into a buffer
		this.curl.SetPost(post,this.easy_handle)
		; this.outPostHash := this.hash(&p := this.curl.easyHandleMap[this.easy_handle]["postData"],"SHA512")
	}
	retrieve(url, headers?, post?, mime?, request?, expiry?, forceBurn?, assetMode?, sideload?){
		/*
			-check if url/etc (fingerprint) exists in db
			-if url doesn't exist -> burn api
				
			-check expiry
			-if url too old -> burn api
				
			-if url (fingerprint) AND expiry is good AND fileblob exists -> return fileblob from db
				?-if file doesn't exist (which it should) -> burn api
		*/

		expiry ??= this.acExpiry
		this.setHeaders(headers?)
		this.setRequest(request?)
		this.setPost(post?)
		mime := unset	;ensures mime is disabled until I'm ready for it.

		this.lastFingerprint := fingerprint := this.generateFingerprint(url
			,	(this.outHeadersText=""?unset:this.outHeadersText)
			,	(!IsSet(post)?unset:post)
			,	unset ;mime (this.outHeadersText=""?unset:this.outHeadersText)
			,	(this.outRequestString=""?unset:this.outRequestString)
			,	1,&h := "")
		
		timestamp := expiry_timestamp := A_NowUTC	;makes the timestamp consistent across the method
		expiry_timestamp := DateAdd(expiry_timestamp, expiry, "seconds")
		;msgbox timestamp "`n" expiry_timestamp
		;big block to jump past a bunch of checks that would otherwise have to be made
		if !IsSet(sideload?) {
			assetOrCache := (!IsSet(assetMode?)?"cache":"asset")
			If !IsSet(forceBurn){	;skips useless db call if set
				selMap := Map(1,Map("Text",fingerprint)
						,	2,Map("Int64",Min(timestamp,expiry_timestamp)))
				this.compiledSQL["retrieve/" assetOrCache].Bind(selMap)
				this.compiledSQL["retrieve/" assetOrCache].Step(&row := Map())
				this.compiledSQL["retrieve/" assetOrCache].Reset()
				If (row.count > 0) {
					this.lastServedSource := "cache"
					return row["data"]
				}
			}

			;if set, chill to keep from hammering the server
			if (this.HasOwnProp("interval") || !this.interval){
				loop {
					;do nothing, but don't sleep to maintain responsiveness
				} until (A_TickCount >= (this.lastRequestTimestamp + this.interval))
			}
			this.lastRequestTimestamp := A_TickCount

			this.curl.SetOpt("URL",url,this.easy_handle)
			this.curl.Sync(this.easy_handle)
			
			response := this.curl.GetLastBody((!IsSet(assetMode)?unset:"Object"),this.easy_handle)
			this.lastStatusCode := this.curl.GetLastStatus(this.easy_handle)
			this.lastResponseHeaders := this.curl.GetLastHeaders(,this.easy_handle)
		} else {	;sideload is set
			;accepts a local file into the database as if this particular request had been made
			;primarily used when the remote offers a bulk download of API data
			;also used to modify stored data with one-time transformations/optimizations
			If !(Type(sideload) = "Buffer"){	;todo - switch on all types
				If !IsSet(assetMode?) {
					response := FileOpen(sideload,"r").Read()
				} else {
					response := Buffer(FileGetSize(sideload))
					FileOpen(sideload,"r").RawRead(response)
				}
			}
			this.lastStatusCode := "-200"
		}

		;validate that a Magic-File response isn't too large for the db
		oversized := ""
		If (Type(response) = "File"){
			oversizedObj := Map()
			oversizedObj["path"] := this.curl._GetFilePathFromFileObject(response)
			oversizedObj["size"] := FileGetSize(oversizedObj["path"])
			msgbox oversizedObj["size"]
			If (oversizedObj["size"] > this.SQLITE_MAX_LENGTH) {
				oversized := "/oversized"
				oversizedObj["hash"] := this.hash(&h := oversizedObj["path"])
				response := JSON.Dump(oversizedObj)
			} else {
				retResponse := Buffer(oversizedObj["size"])
				response.RawRead(retResponse)
				response := retResponse
			}
		}

		;Types := Blob, Double, Int, Int64, Null, Text
		insMap := Map(1,Map("Text",fingerprint)	;fingerprint
				,	2,Map("Int64",timestamp)	;timestamp
				,	3,Map("Int64",expiry_timestamp)	;expiry
				,	4,Map("Text",url)	;url
				,	5,Map((!IsSet(headers)?"NULL":"Text"),(!IsSet(headers)?"NULL":h["headers"]))	;headers
				,	6,Map((!IsSet(post)?"NULL":"Text"),(!IsSet(post)?"NULL":h["post"]))	;post
				,	7,Map("NULL","")	;mime
				,	8,Map((this.outRequestString=""?"NULL":"Text"),(this.outRequestString=""?"NULL":this.outRequestString))	;request
				,	9,Map("Int64",this.lastStatusCode)	;statusCode
				,	10,Map("Text",this.lastResponseHeaders)	;responseHeaders
				,	11,Map((Type(response)!="Buffer"?"Text":"Blob"),response))	;data
		
		this.compiledSQL["retrieve/server"].Bind(insMap)
		this.compiledSQL["retrieve/server"].Step()
		this.compiledSQL["retrieve/server"].Reset()
		this.optimize()

		If !IsSet(sideload?){
			this.lastServedSource := "server" oversized
			return this.curl.GetLastBody((!IsSet(assetMode)?unset:"Object"),this.easy_handle)
		} else {
			this.lastServedSource := "sideload"
			return response
		}
	}
	asset(url, headers?, post?, mime?, request?, expiry?, forceBurn?, sideload?){	;convenience method for assetMode
		return this.retrieve(url, headers?, post?, mime?, request?, expiry?, forceBurn?, 1, sideload?)
	}
	sideload(url, headers?, post?, mime?, request?, expiry?, assetMode?){	;convenience method for sideloading
		return this.retrieve(url, headers?, post?, mime?, request?, expiry?, 1, assetMode?, 1)
	}
	optimize(){
		this.optimizeCounter += 1
		if (this.optimizeCounter < this.optimizeAfterXInserts)
			return
		If (this.openTransaction = 1){
			this.deferredOptimize := 1
			return
		}

		this.acDB.exec("PRAGMA optimize;")
		this.optimizeCounter := 0
		this.deferredOptimize := 0
	}

	buildBulkRetrieve(url, headers?, post?, mime?, request?, expiry?, forceBurn?, assetMode?){
		;queues one fingerprint for .bulkRetrieve()
		
		fingerprintObj := Map()
		fingerprintObj["url"] := url
		fingerprintObj["headers"] := (!IsSet(headers)?unset:headers)
		fingerprintObj["post"] := (!IsSet(post)?unset:post)
		fingerprintObj["mime"] := unset ;(!IsSet(mime)?unset:mime)
		fingerprintObj["request"] := (!IsSet(request)?unset:request)
		fingerprintObj["expiry"] := expiry ??= this.acExpiry
		fingerprintObj["forceBurn"] := (!IsSet(forceBurn)?unset:forceBurn)
		fingerprintObj["assetMode"] := (!IsSet(assetMode)?unset:assetMode)

		this.bulkRetObj.push(fingerprintObj)
	}

	bulkRetrieve(maxConcurrentDownloads := 5){
		stateObj := Map()
		handleObj := []
		loop Min(this.bulkRetObj.length,maxConcurrentDownloads) {	;spawn the easy_handles
			worker := this.curl.EasyInit()
			stateObj[worker] := "waiting"
			handleObj.Push(worker)
			; this.curl.AddEasyToMulti(worker,this.multi_handle)
		}

		loop {
			for easy_handle,state in stateObj {
				switch state {
					case "working":
						continue
					case "waiting":
						if (this.bulkRetObj.Length = 0)
							continue
						fpObj := this.bulkRetObj[1]
						this.bulkRetObj.RemoveAt(1)
						
						
						this.curl.SetOpt("URL",fpObj["url"])
						this.curl.SetHeaders(fpObj["headers"] ??= Map(),easy_handle)
						this.curl.SetOpt("CUSTOMREQUEST",fpObj["request"] ??= "GET",easy_handle)

						If fpObj.Has("post")
							this.curl.SetPost(fpObj["post"],easy_handle)
						else
							this.curl.ClearPost(easy_handle)
						
						
						; fpObj["mime"] := unset	;ensures mime is disabled until I'm ready for it.

						fpObj["expiry"] ??= this.acExpiry
						
						
					case "complete":
						continue

				}
			}
		} until (stateObj.count = 0)
	}


	/*	bulk insert stuff
			
		
		bulkRetrieve(maxConcurrentDownloads := 5, urlObj := ""){
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
	findRecords(urlToMatch?, headersToFP?, postToFP?, mimeToFP?, requestToFP?
		, responseHeadersToMatch?, dataToMatch?){
		;looking for any records which match the parameters
		;unset parameters will not be considered
		;all ToMatch parameters look for partial matches, ToFP parameters are exact
		;will return a results array of fingerprints
		If !IsSet(urlToMatch)
			urlToMatch := ""
			
		this.generateFingerprint(IsSet(urlToMatch)?urlToMatch:""	;method requires url parameter
			,	IsSet(headersToFP)?headersToFP:unset
			,	IsSet(postToFP)?postToFP:unset
			,	IsSet(mimeToFP)?mimeToFP:unset
			,	IsSet(requestToFP)?requestToFP:unset
			,,&h := "")	

		SQL := "SELECT fingerprint `nFROM vRecords_Complete `nWHERE `n"
			.	"INSTR(url," this.sqlQuote(urlToMatch) ")`n"
			.	(IsSet(headersToFP)?"AND headers = '" h["headers"] "'`n":"")
			.	(IsSet(postToFP)?"AND post = '" h["post"] "'`n":"")
			.	(IsSet(mimeToFP)?"AND mime = '" h["mime"] "'`n":"")
			.	(IsSet(requestToFP)?"AND request = '" h["request"] "'`n":"")
			.	(IsSet(responseHeadersToMatch)?"AND INSTR(responseHeaders," this.sqlQuote(responseHeadersToMatch) ")`n":"")
			.	(IsSet(dataToMatch)?"AND INSTR(data," this.sqlQuote(dataToMatch) ")`n":"")
			.	";"

		table := ""
		if !this.acDB.gettable(SQL,&table)
			msgbox a_clipboard "--Failure in findRecords`n" SQL
		retObj := []
		nextObj := Map()
		loop table.rowCount {
			table.nextNamed(&nextObj)
			retObj.push(nextObj["fingerprint"])
		}
		return retObj
	}
	fetchRecords(recordObj){
		;accepts a linear array of fingerprints to return any number of rows
		retObj := []
		for k,v in recordObj {
			fingerprint := v
			SQL := "SELECT * FROM vRecords WHERE fingerprint = '" v "' ORDER BY fingerprint ASC;"
			If !this.acDB.getTable(sql,&table)	;finds data only if it hasn't expired
				msgbox A_Clipboard := "--failed to fetch records`n" sql
			
			; msgbox JSON.Dump(table)
			If (table.RowCount > 0) {	;RowCount will = 0 if nothing found
				table.NextNamed(&record)
				retObj.push(record)
			}
		}
		return retObj
	}
	; findAndFetchRecords(){	;find and fetch records in one step
	; 	;TODO
	; }
	generateFingerprint(url, headers?, post?, mime?, request?, internal?, &hashComponents?){
		;returns a concatonated hash of the outgoing url+headers+post+mime+request
		;fingerprint character length varies based on the # of set parameters
		
		hashComponents := Map()
		hashComponents["url"] := u := this.hash(&url,"SHA512")

		;todo - implement type detection
		If IsSetRef(&headers){
			Switch Type(headers){
				case "Map":
					outHeadersText := ""
					for k,v in headers
						outHeadersText .= k ": " v "`n"
					hashComponents["headers"] := h := this.hash(&outHeadersText,"SHA512")
				Default:
					hashComponents["headers"] := h := this.hash(&headers,"SHA512")
			}
		}

			
		; switch Type(post) {
		; 	case :
				
		; 	default:
				
		; }
		if IsSetRef(&post)
			hashComponents["post"] := p := this.hash(&post,"SHA512")

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
		this.acDB.exec("DELETE FROM apiQache;")
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
		CREATE TABLE apiQache (
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
			FROM apiQache;
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
			FROM apiQache;
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
		SQL := "INSERT OR IGNORE INTO unc.apiQache SELECT * FROM main.vRecords_Complete;"
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
		If (this.deferredOptimize = 1)
			this.optimize()
	}
			
	requestInterval(milliseconds := 100){	;governs how often non-cache requests can be made
		this.interval := milliseconds
	}

	hash(&item:="", hashType:="", c_size:="", cb:="") { ; default hashType = SHA256 /// default enc = UTF-16
		Static _hLib:=DllCall("LoadLibrary","Str","bcrypt.dll","UPtr"), LType:="SHA256", LItem:="", LBuf:="", LSize:="", d_LSize:=1024000
		Static n:={hAlg:0,hHash:0,size:0,obj:""}
			 , o := {md2:n.Clone(),md4:n.Clone(),md5:n.Clone(),sha1:n.Clone(),sha256:n.Clone(),sha384:n.Clone(),sha512:n.Clone()}
		_file:="", LType:=(hashType?StrUpper(hashType):LType), LItem:=(item?item:LItem), ((!o.%LType%.hAlg)?make_obj():"")

		If (!item && !hashType) { ; Free buffers/memory and release objects.
			return !graceful_exit()
		} Else If (Type(LItem) = "File") { ; Determine buffer type.
			_file := LItem, LBuf := true, LSize:=(c_size?c_size:d_LSize)
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
	_cleanup(){
		this.CloseDB()
	}
}