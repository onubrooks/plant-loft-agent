import test from 'node:test';
import assert from 'node:assert/strict';
import {paymentOptions,knowledgeHtml,careGuidesForRequest,paymentDisplay,paymentAmount,requireTestKey,createPaymentOption,verifiedPayment,sendQuoteToThread,quoteMessage} from './workflow.mjs';
const request={id:'req',kind:'RENTAL',customer_reference:'12345',status:'AWAITING_PAYMENT',summary:{owner_approved:true,transport_accepted:true,payment_status:'UNPAID',final_total_kobo:7500000,known_subtotal_kobo:3500000,transport_fee_kobo:4000000}};
test('amount is derived from approved total, never client input',()=>{assert.equal(paymentAmount(request),7500000);assert.throws(()=>paymentAmount({...request,summary:{...request.summary,owner_approved:false}}));assert.throws(()=>paymentAmount({...request,summary:{...request.summary,transport_accepted:false}}));});
test('live keys are refused',()=>{assert.throws(()=>requireTestKey('sk_live_x'));requireTestKey('sk_test_fixture');});
test('verification rejects wrong amount, currency, reference and live domain',()=>{const p={reference:'ref',amount_kobo:7500000},d={domain:'test',status:'success',reference:'ref',currency:'NGN',amount:7500000};assert(verifiedPayment(d,p));for(const patch of [{amount:1},{currency:'USD'},{domain:'live'},{reference:'other'},{status:'pending'}])assert(!verifiedPayment({...d,...patch},p));});
test('checkout must use provider returned reference and correct host',async()=>{const a={method:'CHECKOUT',reference:'ref',amount_kobo:7500000,request_id:'r'};const fetcher=async(u,o)=>{assert.equal(JSON.parse(o.body).amount,7500000);return {ok:true,json:async()=>({status:true,data:{reference:'ref',authorization_url:'https://checkout.paystack.com/test-fixture'}})}};assert.equal((await createPaymentOption(a,'sk_test_fixture',fetcher)).provider_reference,'ref');await assert.rejects(()=>createPaymentOption(a,'sk_test_fixture',async()=>({ok:true,json:async()=>({data:{reference:'ref',authorization_url:'https://evil.example'}})})));});
test('bank details are provider returned, with a valid future expiry',async()=>{const a={method:'BANK_TRANSFER',reference:'ref',amount_kobo:7500000,request_id:'r'},d={status:'pending_bank_transfer',reference:'ref',account_number:'0000000000',account_name:'TEST ONLY',bank:{name:'Test Bank'},account_expires_at:new Date(Date.now()+3600000).toISOString()};const result=await createPaymentOption(a,'sk_test_fixture',async()=>({ok:true,json:async()=>({status:true,data:d})}));assert.equal(result.account_name,'TEST ONLY');});
test('notification checks channel delivery and hands back',async()=>{const paths=[];const f=async(url)=>{paths.push(url);return {ok:true,json:async()=>url.endsWith('/messages')?{id:'message-1',delivery_status:'sent'}:{ok:true}}};assert.equal(await sendQuoteToThread({id:'thread',channel_id:'external_chat',channel_role:'EXTERNAL',control_state:'agent_active'},'quote','https://api.chordhq.xyz','fixture',f),'message-1');assert(paths.at(-1).endsWith('/hand-back'));assert(quoteMessage(request).includes('₦75,000'));});
test('unsafe thread or failed delivery never counts as sent',async()=>{await assert.rejects(()=>sendQuoteToThread({channel_id:'whatsapp'},'x','https://api.chordhq.xyz','fixture'));await assert.rejects(()=>sendQuoteToThread({id:'t',channel_id:'external_chat',channel_role:'EXTERNAL',control_state:'agent_active'},'x','https://api.chordhq.xyz','fixture',async()=>({ok:true,json:async()=>({delivery_status:'failed'})})));});

test('bank expiry is formatted in Lagos time, including date rollover',()=>{const a=paymentDisplay({method:'BANK_TRANSFER',expires_at:'2026-10-25T14:38:00Z'});assert.equal(a.expires_at_lagos,'25 Oct 2026, 15:38 WAT');assert.equal(paymentDisplay({expires_at:'2026-10-25T23:30:00Z'}).expires_at_lagos,'26 Oct 2026, 00:30 WAT');});

const careProducts=[{id:'plant-01',data:{kind:'plant',name:'Snake Plant',recommendation_enabled:true,care:{light:'Bright indirect',watering:'Dry then water',sources:['https://plants.ces.ncsu.edu/plants/dracaena-trifasciata/']}}}];
test('post-purchase care is gated on verified SALE and deduplicates quantities',()=>{const paid={kind:'SALE',summary:{payment_status:'TEST_PAID',items:[{product:'Snake Plant',quantity:2},{product:'Snake Plant',quantity:1}]}};assert.equal(careGuidesForRequest(paid,careProducts).guides.length,1);assert.equal(careGuidesForRequest({...paid,kind:'RENTAL'},careProducts),null);assert.equal(careGuidesForRequest({...paid,summary:{...paid.summary,payment_status:'UNPAID'}},careProducts),null);});
test('missing or held knowledge is reported rather than invented',()=>{const r={kind:'SALE',summary:{payment_status:'TEST_PAID',items:[{product:'Unknown'},{product:'Snake Plant'}]}};const result=careGuidesForRequest(r,careProducts.map(p=>({...p,data:{...p.data,recommendation_enabled:false}})));assert.deepEqual(result.missing,['Unknown','Snake Plant']);assert.equal(result.guides.length,0);});

test('public care HTML escapes markup rather than executing it',()=>{const h=knowledgeHtml('# Test\n<script>alert(1)</script>');assert(!h.includes('<script>'));assert(h.includes('&lt;script&gt;'));});

test('owner bank confirmation is paid without calling Paystack and supports care',async()=>{const r={kind:'SALE',summary:{payment_status:'OWNER_CONFIRMED_TRANSFER_TEST',items:[{product:'Snake Plant'}]}};const p=await paymentOptions(null,r,'sk_test_fixture',true,()=>{throw Error('must not contact provider for owner receipt');});assert.equal(p.verification_source,'OWNER_BANK_CHECK');assert.equal(p.payment_verified,true);assert.equal(careGuidesForRequest(r,careProducts).guides.length,1);});

test('expired transfer account is omitted while checkout remains available',async()=>{
 const r={id:'fixture',status:'AWAITING_PAYMENT',summary:{owner_approved:true,transport_accepted:true,payment_status:'UNPAID',final_total_kobo:10000}};
 const client={rpc:async()=>({data:[{status:'READY',method:'BANK_TRANSFER',amount_kobo:10000,provider_data:{account_number:'0000000000',expires_at:'2020-01-01T00:00:00Z'}},{status:'READY',method:'CHECKOUT',amount_kobo:10000,provider_data:{checkout_url:'https://checkout.paystack.com/fixture'}}]})};
 const result=await paymentOptions(client,r,'sk_test_fixture');assert.equal(result.options.length,1);assert.equal(result.options[0].method,'CHECKOUT');assert.equal(result.payment_verified,false);
});

test('a declined provider verification leaves the request unpaid without applying a receipt',async()=>{
 const calls=[],attempt={id:'p',status:'READY',method:'CHECKOUT',reference:'declined-ref',amount_kobo:7500000,provider_data:{checkout_url:'https://checkout.paystack.com/fixture'}};
 const client={rpc:async(name)=>{calls.push(name);return {data:[attempt]};}};
 const result=await paymentOptions(client,request,'sk_test_fixture',true,async()=>({ok:true,json:async()=>({status:true,data:{domain:'test',status:'failed',reference:'declined-ref',currency:'NGN',amount:7500000,gateway_response:'Declined'}})}));
 assert.equal(result.payment_verified,false);assert.equal(result.payment_status,'UNPAID');assert(!calls.includes('plant_loft_apply_test_payment'));
});
test('provider verification timeout never applies payment or initializes a second charge',async()=>{
 const calls=[],attempt={id:'p',status:'READY',method:'CHECKOUT',reference:'timeout-ref',amount_kobo:7500000,provider_data:{checkout_url:'https://checkout.paystack.com/fixture'}};
 const client={rpc:async(name)=>{calls.push(name);return {data:[attempt]};}};let providerCalls=0;
 const result=await paymentOptions(client,request,'sk_test_fixture',true,async(url,options)=>{providerCalls++;assert.equal(options.method,'GET');throw new DOMException('Verification timed out','TimeoutError');});
 assert.equal(result.payment_verified,false);assert.equal(result.payment_status,'UNPAID');assert.equal(providerCalls,1);assert.deepEqual(calls,['plant_loft_prepare_payments']);
});
test('uncertain checkout creation becomes UNKNOWN rather than being blindly retried',async()=>{
 const writes=[],attempt={id:'p',status:'NEW',method:'CHECKOUT',reference:'create-timeout-ref',amount_kobo:7500000,request_id:'req'};
 const client={rpc:async()=>({data:[attempt]}),from:()=>({update:patch=>{writes.push(patch);const chain={eq:()=>chain,select:async()=>({data:[{id:'p'}]})};return chain;}})};
 const result=await paymentOptions(client,request,'sk_test_fixture',false,async()=>{throw new DOMException('Initialization timed out','TimeoutError');});
 assert.equal(result.payment_verified,false);assert.equal(result.payment_setup_status,'REVIEW_REQUIRED');assert.deepEqual(result.options,[]);assert(writes.some(x=>x.status==='UNKNOWN'));
});
