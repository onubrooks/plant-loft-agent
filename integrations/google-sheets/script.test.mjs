import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
const script=readFileSync(new URL('./Code.gs',import.meta.url),'utf8');
function context(){const c=vm.createContext({SpreadsheetApp:{flush(){}},console});vm.runInContext(script,c);return c;}
test('refresh repairs feedback only for exact committed quote, preserving a new proposal',()=>{
 const c=context(),writes=[];const sh={getLastRow:()=>7,getRange:(r,col,h,w)=>({getValues:()=>[['id',2500,'bank-quote',0,''],['id',3000,'new-proposal',1,'']],setValues:v=>writes.push({r,col,v})})};
 c.reconcileOwnerInputs_({getSheetByName:n=>n==='Owner quotes'?sh:null},{requests:[{id:'id',summary:{transport_fee_kobo:250000,owner_quote_reference:'bank-quote',transport_version:1,final_total_kobo:1800000,transport_accepted:true}}]});
 assert.equal(writes.length,1);assert.equal(writes[0].r,6);assert.equal(writes[0].v[0][0],1);assert.match(writes[0].v[0][1],/Saved.*18000.*accepted/);
});
test('committed save is not reported as failed when refresh fails',()=>{const c=context(),messages=[];c.refreshDashboard=()=>{throw Error('refresh fault');};c.refreshAfterSave_({getRange:()=>({setValue:v=>messages.push(v)})},8,5,'Saved. Total NGN 18000.');assert.match(messages.at(-1),/^Saved.*refresh delayed/);assert(!messages.at(-1).includes('Not saved'));});
test('owner transfer requires checked bank funds and precise amount before any backend call',()=>{const c=context();let calls=0;c.selectedRow_=()=>({values:['id',18000,'bank-ref',1,'Rahama',false]});c.ownerCall_=()=>calls++;assert.throws(()=>c.confirmBankTransfer(),/tick funds received/);assert.equal(calls,0);c.selectedRow_=()=>({values:['id',18000.001,'bank-ref',1,'Rahama',true]});assert.throws(()=>c.confirmBankTransfer(),/exact received amount/);assert.equal(calls,0);});
