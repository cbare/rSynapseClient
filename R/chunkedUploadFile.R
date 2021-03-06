# Upload a local file to Synapse using the 'chunked file' service.
# 
# implements the client side of the Chunked File Upload API defined here:
# https://sagebionetworks.jira.com/wiki/pages/viewpage.action?pageId=31981623
# 
#  Upload a file to be stored in Synapse, dividing large files into chunks.
#  
#  filepath: the file to be uploaded
#  curlHandle
#  chunksize: chop the file into chunks of this many bytes. The default value is
#  5MB, which is also the minimum value.
#  
#  returns an S3FileHandle
#  Author: brucehoff
###############################################################################

chunkedUploadFile<-function(filepath, uploadDestination=S3UploadDestination(), curlHandle=getCurlHandle(), chunksizeBytes=5*1024*1024, contentType=NULL) {
  if (chunksizeBytes < 5*1024*1024)
      stop('Minimum chunksize is 5 MB.')
  
  if (!file.exists(filepath))
    stop(sprintf('File not found: %s',filepath))
  
  debug<-.getCache("debug")
  if (is.null(debug)) debug<-FALSE
  
  chunkNumber <- 1 # service requires that chunk number be >0
  
  # guess mime-type - important for confirmation of MD5 sum by receiver
  if (is.null(contentType)) {
    contentType<-getMimeTypeForFile(basename(filepath))
  }
  
  ## S3 wants 'content-type' and 'content-length' headers. S3 doesn't like
  ## 'transfer-encoding': 'chunked', which requests will add for you, if it
  ## can't figure out content length. The errors given by S3 are not very
  ## informative:
  ## If a request mistakenly contains both 'content-length' and
  ## 'transfer-encoding':'chunked', you get [Errno 32] Broken pipe.
  ## If you give S3 'transfer-encoding' and no 'content-length', you get:
  ## 501 Server Error: Not Implemented
  ## A header you provided implies functionality that is not implemented
  headers <- list('Content-Type'=contentType)
  
  ## get token
  token <- createChunkedFileUploadToken(filepath, uploadDestination, contentType)
  if (debug) {
    message(sprintf('\n\ntoken: %s\n', listToString(token)))
  }
  
  ## define the retry policy for uploading chunks
  # with_retry = RetryRequest(retry_status_codes=[502,503], retries=4, wait=1, back_off=2, verbose=verbose)
  chunkResults<-list()
  connection<-file(filepath, open="rb")
  tryCatch(
    {
      fileSizeBytes<-file.info(filepath)$size
      totalUploadedBytes<-0
      repeat {
        chunk <- readBin(con=connection, what="raw", n=chunksizeBytes)
        if (length(chunk)==0) break
        # get the ith chunk from the file
        if (debug) message(sprintf('\nChunk %d. size %d\n', chunkNumber, length(chunk)))
        
        ## get the signed S3 URL
        chunkRequest <- list(chunkNumber=chunkNumber, chunkedFileToken=token)
        
        curlHandle<-getCurlHandle()

        result<-webRequestWithRetries(
          fcn=function(curlHandle) {
            chunkUploadUrl <- createChunkedFileUploadChunkURL(chunkRequest)
            if (debug) message(sprintf('url= %s\n', chunkUploadUrl))
            
            httpResponse<-.getURLIntern(chunkUploadUrl, 
              postfields=chunk, # the request body
              customrequest="PUT", # the request method
              httpheader=headers, # the headers
              curl=curlHandle, 
              debugfunction=NULL,
			  			.opts=.getCache("curlOpts"))
            # return the http response
						httpResponse$body
          }, 
          curlHandle,
          extraRetryStatusCodes=400 #SYNR-967
        )
        .checkCurlResponse(object=curlHandle, response=result$body, logErrorToSynapse=TRUE)
        
        totalUploadedBytes <- totalUploadedBytes + length(chunk)
        percentUploaded <- totalUploadedBytes*100/fileSizeBytes
        # print progress, but only if there's more than one chunk
        if (chunkNumber>1 | percentUploaded<100) {
          cat(sprintf("Uploaded %.1f%%\n", percentUploaded))
        }
        
        chunkResults[[length(chunkResults)+1]]<-chunkNumber
        chunkNumber <- chunkNumber + 1
      }
    },
    finally=close(connection)
  )
  ## finalize the upload and return a fileHandle
  completeChunkFileUploadWithRetry(token, chunkResults)
}

createChunkedFileUploadToken<-function(filepath, s3UploadDestination, contentType) {
  md5 <- tools::md5sum(path.expand(filepath))
  if (is.na(md5)) stop(sprintf("Unable to compute md5 for %s", filepath))
  names(md5)<-NULL # Needed to make toJSON work right

  if (length(s3UploadDestination@storageLocationId)==0) {
	  chunkedFileTokenRequest<-list(
			  fileName=basename(filepath),
			  contentType=contentType,
			  contentMD5=md5
	  )
  } else {
	  chunkedFileTokenRequest<-list(
			  fileName=basename(filepath),
			  contentType=contentType,
			  contentMD5=md5,
			  storageLocationId=s3UploadDestination@storageLocationId
	  )
  }
  
  synapsePost(uri='/createChunkedFileUploadToken', 
    entity=chunkedFileTokenRequest, 
    endpoint=synapseServiceEndpoint("FILE"),
	extraRetryStatusCodes=NULL)
}

# returns the URL for uploading the specified chunk
createChunkedFileUploadChunkURL<-function(chunkRequest) {
  synapsePost(uri='/createChunkedFileUploadChunkURL', 
    entity=chunkRequest, 
    endpoint=synapseServiceEndpoint("FILE"))
}

completeChunkFileUploadWithRetry<-function(token, chunkResults) {
	INITIAL_BACKOFF_SECONDS <- 1
	BACKOFF_MULTIPLIER <- 2 # i.e. the back off time is (initial)*[multiplier^(# retries)]
	
	maxTries<-.getCache("webRequestMaxTries")
	if (is.null(maxTries) || maxTries<1) stop(sprintf("Illegal value for maxTries %d.", maxTries))
	
	backoff<-INITIAL_BACKOFF_SECONDS
	
	for (retry in 1:maxTries) {
		result<-try(completeChunkFileUpload(token, chunkResults), silent=T)
		if (class(result)=="try-error") {
			Sys.sleep(backoff)
			backoff <- backoff * BACKOFF_MULTIPLIER
		} else {
			break
		}
	}
	
	if (class(result)=="try-error") {
		stop(result[[1]])
	}
	
	result
}



# returns the file handle
completeChunkFileUpload<-function(chunkedFileToken, chunkResults) {
  # start the final assembly
  uploadDaemonStatus = synapsePost(uri='/startCompleteUploadDaemon', 
    entity=list(
      chunkedFileToken=chunkedFileToken, 
      chunkNumbers=chunkResults), 
    endpoint=synapseFileServiceEndpoint())
  statusUri <- sprintf("/completeUploadDaemonStatus/%s", uploadDaemonStatus$daemonId)
  fileHandleId<-NULL
  # wait for the file assembly to complete
  repeat {
    Sys.sleep(0.1) # wait for 1/10 second
    uploadDaemonStatus <- synapseGet(uri=statusUri, endpoint=synapseFileServiceEndpoint())
    if (uploadDaemonStatus$state=="COMPLETED") {
      fileHandleId<-uploadDaemonStatus$fileHandleId
      break
    } else if (uploadDaemonStatus$state=="FAILED") {
      stop(uploadDaemonStatus$errorMessage)
    }
  }
  # retrieve and return the file handle
  handleUri<-sprintf("/fileHandle/%s", fileHandleId)
  synapseGet(handleUri, endpoint=synapseFileServiceEndpoint())
}
