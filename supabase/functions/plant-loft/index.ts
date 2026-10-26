// Narrow server-to-server bridge. No real customers: session_id is model-supplied,
// not verified channel identity. Never widen this demo to live use as-is.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { paymentOptions, notifyQuote, careGuidesForRequest } from './workflow.mjs';
import { careCards } from './care-cards.mjs';

const allowed = new Set(['find_products','prepare_quote','confirm_request','get_request']);
const json = (body: unknown, status = 200) => Response.json(body, {status});
Deno.serve(async (req: Request) => {
 const correlation_id=crypto.randomUUID();
 try {
  const pathname=new URL(req.url).pathname;
  // Public, compiled horticultural text only. No database or secret access here.
  const carePath=pathname.match(/\/knowledge\/(guide|plant-\d{2})$/);
  if(req.method==='GET'&&carePath) {
    const card=careCards[carePath[1]];
    return card?new Response(card,{headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'public, max-age=300','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",'X-Content-Type-Options':'nosniff'}}):json({error:'Guide not found'},404);
  }
  if (req.method !== 'POST') return json({error:'POST required'},405);
  const ownerMatch=pathname.match(/\/owner\/(snapshot|transport|confirm_transfer|delivered|returned|approve_stock)$/);
  const ownerAction=ownerMatch?.[1]||null;
  const expected = Deno.env.get(ownerAction?'PLANT_LOFT_OWNER_KEY':'PLANT_LOFT_TOOL_KEY');
  if (!expected || expected.length < 32) return json({error:'Tool authentication not configured'},503);
  const presented = req.headers.get('x-plant-loft-key') || '';
  // Hash fixed-length digests to avoid comparing variable-length secrets directly.
  const digest = async (s: string) => new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
  const a=await digest(expected), b=await digest(presented);
  let different=0; for(let i=0;i<a.length;i++) different|=a[i]^b[i];
  if(different) return json({error:'Unauthorized'},401);
  const raw=await req.text();
  if(new TextEncoder().encode(raw).length>16384) return json({error:'Body too large'},413);
  let input;
  try { input=JSON.parse(raw); } catch {
    console.warn('invalid_json_body',JSON.stringify({length:raw.length}));
    return json({error:'Invalid JSON'},400);
  }
  const route=new URL(req.url).pathname.split('/').filter(Boolean).pop();
  if(!input || typeof input!=='object' || Array.isArray(input)){
    console.log('invalid_tool_shape',JSON.stringify({route,type:typeof input}));
    return json({error:'Invalid tool request'},400);
  }
  // Accept the OpenAPI envelope and direct endpoint fields. Empty bodies remain
  // invalid; a route-only test is not a valid business-tool invocation.
  const action=ownerAction || (allowed.has(route||'') ? route! : input.action);
  if(input.action && input.action!==action) return json({error:'Action and route disagree'},400);
  const payload=input.payload && typeof input.payload==='object' && !Array.isArray(input.payload)
    ? input.payload : {...input};
  delete payload.action;
  if((!ownerAction && !allowed.has(action)) || typeof payload!=='object' || Array.isArray(payload)){
    console.log('invalid_tool_shape',JSON.stringify({route,keys:Object.keys(input).sort()}));
    return json({error:'Invalid tool request'},400);
  }
  // Catalogue browsing has no sensitive/customer-specific data. A missing
  // synthetic session identifier may be generated for this read-only path.
  if(action==='find_products' && !payload.session_id) payload.session_id='browse-'+crypto.randomUUID();
  const client=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
  let {data,error}=await client.rpc(ownerAction?'plant_loft_owner':'plant_loft_tool',{action,payload}).abortSignal(AbortSignal.timeout(8000));
  if(error){
    console.error(JSON.stringify({action,code:error.code}));
    if(error.code==='P0001' || error.code?.startsWith('22')) return json({ok:false,error:error.code==='P0001'?error.message:'Invalid field format',customer_message:'We could not record that change. Please check the requested details; do not create a replacement order.',correlation_id},422);
    return json({ok:false,error:'Service unavailable. Recover the same request before retrying.',customer_message:'We could not check or record that update just now. Please keep your reference and ask us to check again.',correlation_id},503);
  }
  if(ownerAction==='transport') {
    const config={key:Deno.env.get('CHORD_API_KEY'),workspace:Deno.env.get('CHORD_WORKSPACE_ID'),teammate:'YOUR_CHORD_TEAMMATE_ID'};
    data.notification_status=data.summary?.transport_accepted===true?'ALREADY_ACCEPTED':config.key&&config.workspace?'QUEUED':'PENDING_CONFIGURATION';
    // Owner write has committed. Do not hold the Sheet's response open while routing a message.
    if(data.notification_status==='QUEUED')EdgeRuntime.waitUntil(notifyQuote(client,data,config));
  }
  if(!ownerAction && ['confirm_request','get_request'].includes(action) && data?.id) {
    const options=await paymentOptions(client,data,Deno.env.get('PAYSTACK_TEST_SECRET_KEY'),payload.check_payment===true);
    if(options.payment_verified) {
      const refreshed=await client.rpc('plant_loft_tool',{action:'get_request',payload:{quote_code:data.quote_code}});
      if(!refreshed.error)data=refreshed.data;
    }
    data={...data,...options,payment_options:options.options||[]};
    if(data.kind==='SALE'&&['TEST_PAID','OWNER_CONFIRMED_TRANSFER_TEST'].includes(data.summary?.payment_status)) {
      const catalogue=await client.from('plant_loft_products').select('id,data');
      data.care_guides=catalogue.error?{guides:[],missing:['Catalogue temporarily unavailable'],delivery_status:'UNAVAILABLE'}:careGuidesForRequest(data,catalogue.data||[]);
    }
  }
  if(action==='find_products' && data?.products){
    const paths=[...new Set(data.products.map((p: {image_path: string})=>p.image_path.split('/').pop()))] as string[];
    const {data:signed,error:imagesError}=await client.storage.from('plant-loft-images').createSignedUrls(paths,3600);
    const urls=new Map((signed||[]).map(s=>[s.path,s.signedUrl]));
    data.products=data.products.map((p: {image_path: string})=>({...p,
      image_url:urls.get(p.image_path.split('/').pop())||null,
      image_expires_in_seconds:3600}));
    data.image_warning=imagesError?'Photo service unavailable; do not claim images were sent.':null;
  }
  return json({ok:true,demo:true,result:data});
 } catch {
  console.error(JSON.stringify({correlation_id,error:'UNEXPECTED_TOOL_FAILURE'}));
  return json({ok:false,error:'Service temporarily unavailable',customer_message:'We could not check that update just now. Please keep your reference and ask us to check again.',correlation_id},503);
 }
});
