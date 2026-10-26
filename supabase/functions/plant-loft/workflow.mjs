// Test-only provider adapters. No secrets or customer card data enter model context.
export function paymentAmount(request) {
  const s=request.summary||{}, amount=Number(s.final_total_kobo);
  if(request.status!=='AWAITING_PAYMENT'||s.owner_approved!==true||s.transport_accepted!==true||s.payment_status!=='UNPAID') throw Error('PAYMENT_NOT_READY');
  if(!Number.isSafeInteger(amount)||amount<=0) throw Error('INVALID_PAYMENT_AMOUNT');
  return amount;
}
export function requireTestKey(key) { if(!key?.startsWith('sk_test_'))throw Error('PAYSTACK_TEST_KEY_REQUIRED'); }
export async function providerJson(url,key,body,fetcher=fetch) {
  const response=await fetcher(url,{method:body?'POST':'GET',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});
  const data=await response.json();
  if(!response.ok||data.status===false)throw Error('PROVIDER_REQUEST_FAILED');
  return data;
}
export async function createPaymentOption(attempt,key,fetcher=fetch) {
  requireTestKey(key);
  const base={amount:attempt.amount_kobo,email:`plant-loft-test+${attempt.request_id}@example.com`,currency:'NGN',reference:attempt.reference};
  if(attempt.method==='CHECKOUT') {
    const r=await providerJson('https://api.paystack.co/transaction/initialize',key,{...base,channels:['card','bank_transfer']},fetcher);
    const u=new URL(r.data?.authorization_url);
    if(u.protocol!=='https:'||u.hostname!=='checkout.paystack.com'||u.username||u.password||r.data.reference!==attempt.reference)throw Error('INVALID_CHECKOUT_RESULT');
    return {checkout_url:u.href,provider_reference:r.data.reference};
  }
  const r=await providerJson('https://api.paystack.co/charge',key,{...base,bank_transfer:{account_expires_at:new Date(Date.now()+3600000).toISOString()}},fetcher), d=r.data;
  if(d?.status!=='pending_bank_transfer'||d.reference!==attempt.reference||!/^\d{10}$/.test(d.account_number||'')||!d.account_name||!d.bank?.name||!Number.isFinite(Date.parse(d.account_expires_at))||Date.parse(d.account_expires_at)<=Date.now())throw Error('INVALID_TRANSFER_RESULT');
  return {bank_name:d.bank.name,account_name:d.account_name,account_number:d.account_number,expires_at:d.account_expires_at,provider_reference:d.reference};
}
export function verifiedPayment(data,attempt) {
  return data?.domain==='test'&&data.status==='success'&&data.reference===attempt.reference&&data.currency==='NGN'&&Number(data.amount)===Number(attempt.amount_kobo);
}
export function careGuidesForRequest(request,products) {
  // Purchased items come from the stored quote, never an event or model claim.
  if(request.kind!=='SALE'||!['TEST_PAID','OWNER_CONFIRMED_TRANSFER_TEST'].includes(request.summary?.payment_status))return null;
  const wanted=[...new Set((request.summary.items||[]).map(x=>x.product).filter(Boolean))];
  const guides=[],missing=[];
  for(const name of wanted) {
    const p=products.find(x=>x.data?.kind==='plant'&&x.data.name===name), c=p?.data?.care;
    if(!p?.data?.recommendation_enabled||!c?.light||!c?.watering||!c?.sources?.length){missing.push(name);continue;}
    guides.push({product_id:p.id,name,light:c.light,watering:c.watering,pet_safety:c.pet_safety,
      guide_url:`https://YOUR_PROJECT_REF.supabase.co/functions/v1/plant-loft/knowledge/${p.id}`,
      identity_status:c.identity_status,sources:c.sources,reviewed_at:c.reviewed_at});
  }
  return {version:'care-v1-2026-10-25',guides,missing,
    common_tip:'Check the growing mix before watering; let excess water drain and empty the decorative cover pot.',
    delivery_status:'AVAILABLE_FOR_CURRENT_REPLY',
    note:'Guide content is not evidence of an outbound message. Include a short guide for each purchased plant in the verified-payment reply. Do not repeatedly resend unless requested.'};
}
export function knowledgeHtml(card) {
  const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const lines=card.split('\n').map(line=>{
    if(line.startsWith('# '))return '<h1>'+esc(line.slice(2))+'</h1>';
    if(line.startsWith('## '))return '<h2>'+esc(line.slice(3))+'</h2>';
    if(line.startsWith('- https://')) {
      const url=line.slice(2);return `<p><a href="${esc(url)}" rel="noreferrer">${esc(url)}</a></p>`;
    }
    return line?'<p>'+esc(line)+'</p>':'';
  }).join('\n');
  return '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Plant Loft care guide</title><style>body{font:17px/1.65 system-ui,sans-serif;color:#173b31;background:#f6f8f3;margin:0}main{max-width:760px;margin:auto;padding:28px 24px}h1{font-size:30px}h2{margin-top:36px}a{color:#16614b;overflow-wrap:anywhere}p{margin:12px 0}</style><main>'+lines+'</main></html>';
}
export function paymentDisplay(option) {
  if(!option.expires_at)return option;
  const when=new Date(option.expires_at);
  if(!Number.isFinite(when.getTime()))throw Error('INVALID_PAYMENT_EXPIRY');
  return {...option,expires_at_lagos:new Intl.DateTimeFormat('en-GB',{
    timeZone:'Africa/Lagos',dateStyle:'medium',timeStyle:'short',hourCycle:'h23'
  }).format(when)+' WAT',expiry_timezone:'Africa/Lagos'};
}
export async function paymentOptions(client,request,key,check=false,fetcher=fetch) {
  if(['TEST_PAID','OWNER_CONFIRMED_TRANSFER_TEST'].includes(request.summary?.payment_status))return {payments_configured:true,payment_verified:true,payment_status:request.summary.payment_status,verification_source:request.summary.payment_status==='TEST_PAID'?'PAYSTACK':'OWNER_BANK_CHECK',options:[]};
  if(!key)return {payments_configured:false,payment_setup_status:'PAYSTACK_TEST_KEY_MISSING'};
  try {requireTestKey(key);paymentAmount(request);}catch(e){return {payments_configured:false,payment_setup_status:e.message};}
  const prepared=await client.rpc('plant_loft_prepare_payments',{request_uuid:request.id});
  if(prepared.error)return {payments_configured:false,payment_setup_status:'PAYMENT_PREPARATION_FAILED'};
  const options=[];
  for(const a of prepared.data) {
    if(check&&a.status==='READY') {
      try {
        const v=await providerJson(`https://api.paystack.co/transaction/verify/${encodeURIComponent(a.reference)}`,key,undefined,fetcher);
        if(verifiedPayment(v.data,a)) {
          const applied=await client.rpc('plant_loft_apply_test_payment',{payment_reference:a.reference});
          if(!applied.error)return {payments_configured:true,payment_verified:true,payment_status:'TEST_PAID',options:[]};
        }
      }catch { /* A failed read never turns an unpaid order into paid. */ }
    }
    if(a.status==='READY') {
      if(!a.provider_data.expires_at||Date.parse(a.provider_data.expires_at)>Date.now())options.push({method:a.method,amount_kobo:a.amount_kobo,...a.provider_data});
      continue;
    }
    if(a.status!=='NEW')continue;
    const claimed=await client.from('plant_loft_payment_attempts').update({status:'CREATING'}).eq('id',a.id).eq('status','NEW').select('id');
    if(claimed.error||claimed.data?.length!==1)continue;
    try {
      const p=await createPaymentOption(a,key,fetcher);
      const saved=await client.from('plant_loft_payment_attempts').update({status:'READY',provider_data:p}).eq('id',a.id).eq('status','CREATING');
      if(saved.error)throw Error('PROVIDER_RESULT_PERSISTENCE_FAILED');
      options.push({method:a.method,amount_kobo:a.amount_kobo,...p});
    }catch {
      // The provider might have committed. Do not initialize again blindly.
      await client.from('plant_loft_payment_attempts').update({status:'UNKNOWN'}).eq('id',a.id).eq('status','CREATING');
    }
  }
  return {payments_configured:true,payment_verified:false,payment_status:'UNPAID',options:options.map(paymentDisplay),payment_setup_status:options.length?'READY':'REVIEW_REQUIRED'};
}
export function quoteMessage(request) {
  const s=request.summary, fmt=x=>new Intl.NumberFormat('en-NG').format(Number(x)/100);
  return `Your final quote is ready.\nReference: ${request.customer_reference}\n${request.kind==='RENTAL'?'Rental':'Items'}: ₦${fmt(s.known_subtotal_kobo)}\n${request.kind==='RENTAL'?'Delivery and collection':'Delivery fee'}: ₦${fmt(s.transport_fee_kobo)}\nTotal: ₦${fmt(s.final_total_kobo)}\nAvailability is approved. Do you accept this total?`;
}
export async function sendQuoteToThread(thread,text,chord,key,fetcher=fetch) {
  if(thread.channel_id!=='external_chat'||thread.channel_role!=='EXTERNAL'||thread.control_state!=='agent_active')throw Error('UNSAFE_OR_BUSY_THREAD');
  const post=async(path,body)=>{
    const r=await fetcher(`${chord}/v1/threads/${thread.id}/${path}`,{method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(8000)});
    if(!r.ok)throw Error('CHORD_REQUEST_FAILED');return r.json();
  };
  await post('take-over',{reason:'Delivering owner-approved quote'});
  try {
    const sent=await post('messages',{text});
    if(sent.delivery_status!=='sent')throw Error('CHORD_MESSAGE_NOT_DELIVERED');
    return sent.id;
  }finally {await post('hand-back',{reason:'Owner quote delivered; customer may continue with the assistant'});}
}
export async function notifyQuote(client,request,config,fetcher=fetch) {
  if(request.summary?.transport_accepted===true)return 'ALREADY_ACCEPTED';
  if(!config.key||!config.workspace)return 'PENDING_CONFIGURATION';
  const {data:n,error}=await client.from('plant_loft_notification_outbox').select('*').eq('request_id',request.id).eq('transport_version',request.summary.transport_version).single();
  if(error||!n)return 'OUTBOX_UNAVAILABLE';
  if(['SENT','SENDING','UNKNOWN'].includes(n.status))return n.status;
  const {data:q}=await client.from('plant_loft_quotes').select('tracking_code').eq('id',request.quote_id).single();
  if(!q)return 'UNRESOLVED_THREAD';
  const call=async path=>{const r=await fetcher(`https://api.chordhq.xyz${path}`,{headers:{Authorization:`Bearer ${config.key}`},signal:AbortSignal.timeout(8000)});if(!r.ok)throw Error('CHORD_READ_FAILED');return r.json();};
  try {
    const page=await call(`/v1/threads?workspace_id=${encodeURIComponent(config.workspace)}&agent_id=${encodeURIComponent(config.teammate)}&channel_id=external_chat&limit=50`), matches=[];
    if(page.has_more)throw Error('THREAD_LOOKUP_LIMIT_REVIEW_REQUIRED');
    // Bound the search. No guessed name/phone matching and no cross-workspace route.
    for(const t of (page.threads||[])) {
      if(t.workspace_id!==config.workspace||t.channel_id!=='external_chat'||t.channel_role!=='EXTERNAL')continue;
      const turns=await call(`/v1/threads/${t.id}/turns?limit=50`);
      if((turns.turns||[]).some(x=>x.content?.text?.includes(q.tracking_code)))matches.push(t);
    }
    if(matches.length!==1)throw Error('UNRESOLVED_OR_AMBIGUOUS_THREAD');
    const claimed=await client.from('plant_loft_notification_outbox').update({status:'SENDING',thread_id:matches[0].id}).eq('id',n.id).in('status',['PENDING_CONFIGURATION','PENDING','FAILED']).select('id');
    if(claimed.error||claimed.data?.length!==1)return 'NOT_CLAIMED';
    try {
      const id=await sendQuoteToThread(matches[0],quoteMessage(request),'https://api.chordhq.xyz',config.key,fetcher);
      const saved=await client.from('plant_loft_notification_outbox').update({status:'SENT',provider_message_id:id,error_code:null}).eq('id',n.id);
      return saved.error?'UNKNOWN':'SENT';
    }catch {
      await client.from('plant_loft_notification_outbox').update({status:'UNKNOWN',error_code:'DELIVERY_OR_HAND_BACK_UNCERTAIN'}).eq('id',n.id);
      return 'UNKNOWN';
    }
  }catch(e){return e.message;}
}
