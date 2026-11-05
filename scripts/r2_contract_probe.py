import argparse
import base64
import concurrent.futures
import datetime
import hashlib
import hmac
import json
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description='Opt-in R2 conditional write contract probe; uses synthetic data only.')
parser.add_argument('--account-id', required=True)
parser.add_argument('--bucket', required=True)
parser.add_argument('--credentials-file', required=True, type=Path)
parser.add_argument('--jurisdiction', choices=['standard', 'eu'], default='standard')
parser.add_argument('--report-file', type=Path)
parser.add_argument('--allow-test-writes', action='store_true', required=True,
                    help='Create and delete only synthetic objects under a fresh s3-mountain-tests UUID prefix')
args = parser.parse_args()
if not re.fullmatch('[a-fA-F0-9]{32}', args.account_id):
    parser.error('Invalid Account ID format')
if not re.fullmatch('[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', args.bucket):
    parser.error('Invalid bucket format')
HOST = args.account_id + ('.eu' if args.jurisdiction == 'eu' else '') + '.r2.cloudflarestorage.com'
BUCKET = args.bucket
PREFIX = 's3-mountain-tests/' + str(uuid.uuid4()) + '/'
KEYS = set()
UPLOADS = []

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

opener = urllib.request.build_opener(NoRedirect())
raw = args.credentials_file.read_text()
try:
    credential_json = json.loads(raw)
except ValueError:
    credential_json = None
if isinstance(credential_json, dict) and isinstance(credential_json.get('accessKeyID', credential_json.get('accessKeyId')), str) and isinstance(credential_json.get('secretAccessKey'), str):
    access_id = credential_json.get('accessKeyID', credential_json.get('accessKeyId'))
    secret = credential_json['secretAccessKey']
else:
    tokens = set(re.findall(r'cfat_[A-Za-z0-9_-]+',raw))
    secrets = set(re.findall(r'(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])',raw))
    if len(tokens) != 1 or len(secrets) != 1:
        parser.error('Provide JSON accessKeyId and secretAccessKey, or a matching API token and secret. Values never displayed.')
    token = next(iter(tokens)); secret = next(iter(secrets))
    if hashlib.sha256(token.encode()).hexdigest() != secret:
        parser.error('Token and secret do not match; values never displayed.')
    request = urllib.request.Request('https://api.cloudflare.com/client/v4/accounts/' + args.account_id + '/tokens/verify', headers={'Authorization':'Bearer '+token})
    try:
        with opener.open(request, timeout=20) as response:
            verification=json.load(response)
    except Exception:
        parser.error('Could not verify account token; values never displayed.')
    if not verification.get('success') or verification.get('result',{}).get('status') != 'active':
        parser.error('Account token is not active; values never displayed.')
    access_id=verification['result']['id']
if not re.fullmatch('[0-9a-fA-F]{32}',access_id) or access_id.lower() == args.account_id.lower():
    parser.error('A distinct S3 Access Key ID is required; Account ID is not Access Key ID.')

def sign(key, value):
    return hmac.new(key, value.encode(), hashlib.sha256).digest()

def call(method,key,query=(),body=None,extra=None):
    assert key.startswith(PREFIX), 'Request escaped generated test prefix'
    now=datetime.datetime.now(datetime.timezone.utc)
    date=now.strftime('%Y%m%d'); stamp=now.strftime('%Y%m%dT%H%M%SZ')
    path='/'+BUCKET+'/'+urllib.parse.quote(key,safe='/-_.~')
    canonical_query='&'.join(k+'='+v for k,v in sorted((urllib.parse.quote(str(k),safe='-_.~'),urllib.parse.quote(str(v),safe='-_.~')) for k,v in query))
    headers={'host':HOST,'x-amz-date':stamp,'x-amz-content-sha256':'UNSIGNED-PAYLOAD'}
    if extra: headers.update(extra)
    if body is not None: headers['content-length']=str(len(body))
    names=';'.join(sorted(headers))
    canonical_headers=''.join(k+':'+str(headers[k]).strip()+'\n' for k in sorted(headers))
    canonical='\n'.join([method,path,canonical_query,canonical_headers,names,'UNSIGNED-PAYLOAD'])
    scope=date+'/auto/s3/aws4_request'
    string_to_sign='AWS4-HMAC-SHA256\n'+stamp+'\n'+scope+'\n'+hashlib.sha256(canonical.encode()).hexdigest()
    signing_key=sign(sign(sign(sign(('AWS4'+secret).encode(),date),'auto'),'s3'),'aws4_request')
    signature=hmac.new(signing_key,string_to_sign.encode(),hashlib.sha256).hexdigest()
    headers['authorization']='AWS4-HMAC-SHA256 Credential='+access_id+'/'+scope+', SignedHeaders='+names+', Signature='+signature
    url='https://'+HOST+path+('?' + canonical_query if canonical_query else '')
    req=urllib.request.Request(url,data=body,headers=headers,method=method)
    try:
        with opener.open(req,timeout=60) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code,dict(error.headers),error.read()

def xmlvalue(body,tag):
    root=ET.fromstring(body)
    return next((x.text for x in root.iter() if x.tag.rsplit('}',1)[-1]==tag),None)

def errcode(body):
    try: value=xmlvalue(body,'Code') or ''
    except ET.ParseError: return 'NonXML'
    if not value: return ''
    return value if re.fullmatch('[A-Za-z0-9_-]{1,80}',value) else 'Unknown'

def need(status,expected,body):
    if status!=expected: raise RuntimeError('UnexpectedHTTP:'+str(status)+':'+errcode(body))

def md5(data): return base64.b64encode(hashlib.md5(data).digest()).decode()

def put(key,data):
    KEYS.add(key)
    return call('PUT',key,body=data,extra={'content-md5':md5(data),'if-none-match':'*','x-amz-meta-s3-mountain-job-id':str(uuid.uuid4())})

def multipart(key,suffix):
    KEYS.add(key)
    status,headers,body=call('POST',key,query=[('uploads','')],body=b'',extra={'x-amz-meta-s3-mountain-job-id':str(uuid.uuid4())})
    need(status,200,body); upload=xmlvalue(body,'UploadId'); assert upload
    UPLOADS.append((key,upload))
    parts=[]; data=b'M'*(5*1024*1024)+suffix
    for number,chunk in enumerate((data[:5*1024*1024],data[5*1024*1024:]),1):
        status,headers,body=call('PUT',key,query=[('uploadId',upload),('partNumber',number)],body=chunk,extra={'content-md5':md5(chunk)})
        need(status,200,body)
        etag=next(v for k,v in headers.items() if k.lower()=='etag')
        assert etag.strip('"')==hashlib.md5(chunk).hexdigest()
        parts.append((number,etag))
    status,headers,body=call('GET',key,query=[('uploadId',upload)])
    need(status,200,body)
    root=ET.fromstring(body)
    listed=[x for x in root.iter() if x.tag.rsplit('}',1)[-1]=='Part']
    assert len(listed)==2
    complete=ET.Element('CompleteMultipartUpload')
    for number,etag in parts:
        p=ET.SubElement(complete,'Part')
        ET.SubElement(p,'PartNumber').text=str(number)
        ET.SubElement(p,'ETag').text=etag
    return upload,ET.tostring(complete),data

def finish(key,upload,xml):
    status,headers,body=call('POST',key,query=[('uploadId',upload)],body=xml,extra={'if-none-match':'*','content-type':'application/xml'})
    return status,errcode(body),body

def content(key):
    status,headers,body=call('GET',key)
    need(status,200,body); return body

report={'bucket':BUCKET,'test_data':'synthetic, isolated random prefix','results':{}}
failure=None
try:
    key=PREFIX+'small.bin'; sentinel=b's3-mountain synthetic sentinel'
    status,headers,body=put(key,sentinel); need(status,200,body)
    status,headers,body=put(key,b'replacement')
    report['results']['conditional_put']={'status':status,'sentinel_unchanged':content(key)==sentinel}
    positive_key=PREFIX+'multipart-positive.bin'
    upload,xml,data=multipart(positive_key,b'positive')
    status,code,body=finish(positive_key,upload,xml)
    report['results']['conditional_complete_positive']={'status':status,'code':code,'content_matches':status==200 and content(positive_key)==data}
    existing_key=PREFIX+'multipart-existing.bin'
    status,headers,body=put(existing_key,sentinel); need(status,200,body)
    upload,xml,data=multipart(existing_key,b'conflict')
    status,code,body=finish(existing_key,upload,xml)
    report['results']['conditional_complete_existing']={'status':status,'code':code,'sentinel_unchanged':content(existing_key)==sentinel}
    race_key=PREFIX+'multipart-race.bin'
    first=multipart(race_key,b'first'); second=multipart(race_key,b'second')
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(finish,race_key,u,x) for u,x,d in (first,second)]
        outcomes=[future.result() for future in futures]
    winners=[i for i,outcome in enumerate(outcomes) if outcome[0]==200 and outcome[1]=='']
    final=content(race_key)
    report['results']['conditional_complete_race']={'statuses':[x[0] for x in outcomes],'codes':[x[1] for x in outcomes],'successes':len(winners),'winner_content_matches':len(winners)==1 and final==(first,second)[winners[0]][2]}
    checks=report['results']
    report['contract_passed']=(checks['conditional_put']['status']==412 and checks['conditional_put']['sentinel_unchanged'] and checks['conditional_complete_positive']['status']==200 and checks['conditional_complete_positive']['content_matches'] and checks['conditional_complete_existing']['status']==412 and checks['conditional_complete_existing']['sentinel_unchanged'] and checks['conditional_complete_race']['successes']==1 and checks['conditional_complete_race']['winner_content_matches'])
except Exception as error:
    failure=type(error).__name__
    if isinstance(error,RuntimeError) and str(error).startswith('UnexpectedHTTP:'): failure=str(error)
    report['error']=failure
finally:
    cleanup=[]
    for key,upload in UPLOADS:
        try:
            status,headers,body=call('DELETE',key,query=[('uploadId',upload)])
            if status not in (200,204,404): cleanup.append({'kind':'multipart','status':status})
        except Exception as error: cleanup.append({'kind':'multipart','error':type(error).__name__})
    for key in KEYS:
        try:
            status,headers,body=call('DELETE',key)
            if status not in (200,204,404): cleanup.append({'kind':'object','status':status})
        except Exception as error: cleanup.append({'kind':'object','error':type(error).__name__})
    report['cleanup_errors']=cleanup
    report['cleanup_passed']=not cleanup
    print(json.dumps(report,indent=2))
    if args.report_file:
        args.report_file.write_text(json.dumps(report,indent=2)+'\n')
sys.exit(0 if report.get('contract_passed') and report['cleanup_passed'] else 1)
