/** @OnlyCurrentDoc */
const EDGE_BASE='https://YOUR_PROJECT_REF.supabase.co/functions/v1/plant-loft';
const EXPECTED_SHEET='1JFv98oENDj9T-pLwemD2u2TlpjT0vUtAG0VtCHzxdLM';
function onOpen(){SpreadsheetApp.getUi().createMenu('Plant Loft').addItem('Refresh dashboard','refreshDashboard').addItem('Save selected delivery quote','saveTransportQuote').addItem('Confirm selected bank transfer','confirmBankTransfer').addItem('Save selected fulfilment action','saveFulfilment').addToUi();}
function ownerCall_(action,payload){
 const key=PropertiesService.getScriptProperties().getProperty('OWNER_KEY');
 if(!key)throw new Error('OWNER_KEY is missing from Script properties');
 const response=UrlFetchApp.fetch(EDGE_BASE+'/owner/'+action,{method:'post',contentType:'application/json',headers:{'x-plant-loft-key':key},payload:JSON.stringify({payload:payload||{}}),muteHttpExceptions:true});
 const body=JSON.parse(response.getContentText());
 if(response.getResponseCode()!==200||!body.ok)throw new Error(body.error||'Backend unavailable');
 return body.result;
}
function spreadsheet_(){const ss=SpreadsheetApp.getActiveSpreadsheet();if(!ss||ss.getId()!==EXPECTED_SHEET)throw new Error('Run from the original Plant Loft spreadsheet');return ss;}
function text_(v){const s=v==null?'':String(v);return /^[=+\-@]/.test(s)?"'"+s:s;}
function time_(v){return new Date(v).getTime()/86400000+25569;}
function replaceRows_(sheet, rows, width) {
  if (!rows.every(row =>
    Array.isArray(row) && row.length === width
  )) {
    throw new Error('Refresh row width does not match destination');
  }

  const count = Math.max(sheet.getLastRow() - 5, rows.length, 0);
  if (!count) return;

  const requiredRows = count + 5;
  if (requiredRows > sheet.getMaxRows()) {
    sheet.insertRowsAfter(
      sheet.getMaxRows(),
      requiredRows - sheet.getMaxRows()
    );
  }

  const values = Array.from({length: count}, (_, index) =>
    index < rows.length ? rows[index] : Array(width).fill('')
  );

  sheet.getRange(6, 1, count, width).setValues(values);
}
function refreshDashboard(){
 const lock=LockService.getScriptLock();if(!lock.tryLock(5000))return;
 const ss=spreadsheet_(),dash=ss.getSheetByName('Dashboard');
 try{
  const data=ownerCall_('snapshot',{});if(data.demo!==true)throw new Error('This dashboard accepts synthetic demo data only');
  if(data.requests.length>5000||data.events.length>5000)throw new Error('Demo export limit reached; archive explicitly before extending');
  const req=ss.getSheetByName('Requests'),events=ss.getSheetByName('Interactions');
  [req,events].forEach(s=>{if(s.getMaxRows()<5005)s.insertRowsAfter(s.getMaxRows(),5005-s.getMaxRows());});
  req.getRange('A5:O5').setValues([['Request ID','Type','Status','Known subtotal (NGN)','Final total (NGN)','Transport','Payment','Created (UTC)','Quote ID','Transport version','Customer reference','Fulfilment','Payment verification','Product rating','Service rating']]);
  replaceRows_(req,[...data.requests].sort((a,b)=>Date.parse(b.created_at)-Date.parse(a.created_at)||String(b.id).localeCompare(String(a.id))).map(r=>[r.id,r.kind,r.status,Number(r.summary.known_subtotal_kobo)/100,r.summary.final_total_kobo==null?'':Number(r.summary.final_total_kobo)/100,r.summary.transport_status,r.summary.payment_status,time_(r.created_at),r.quote_id,Number(r.summary.transport_version||0),r.customer_reference||'',r.summary.fulfilment_status||'NOT_DELIVERED',r.summary.payment_verification||((r.summary.payment_status==='TEST_PAID')?'PAYSTACK':''),(data.reviews||[]).find(v=>v.request_id===r.id)?.product_rating||'',(data.reviews||[]).find(v=>v.request_id===r.id)?.service_rating||'']),15);
  req.getRange('D6:D5005').setNumberFormat('#,##0.00');req.getRange('E6:E5005').setNumberFormat('#,##0.00');req.getRange('H6:H5005').setNumberFormat('yyyy-mm-dd hh:mm');
  events.getRange('A5:G5').setValues([['Event ID','Created (UTC)','Stage','Type','Request ID','Quote ID','Details']]);
  replaceRows_(events,data.events.map(e=>[Number(e.id),time_(e.created_at),text_(e.stage),text_(e.kind),text_(e.request_id),text_(e.quote_id),'']),7);
  events.getRange('B6:B5005').setNumberFormat('yyyy-mm-dd hh:mm');
  dash.getRange('B6:B8').setFormulas([['=COUNTIF(Interactions!$C$6:$C$5005,"catalogue_viewed")'],['=COUNTIF(Interactions!$C$6:$C$5005,"quoted")'],['=COUNTIF(Interactions!$C$6:$C$5005,"request_confirmed")']]);
  dash.getRange('E6:E7').setFormulas([['=SUMIF(Requests!$B$6:$B$5005,D6,Requests!$D$6:$D$5005)'],['=SUMIF(Requests!$B$6:$B$5005,D7,Requests!$D$6:$D$5005)']]);
  dash.getRange('E9').setFormula('=SUMIF(Requests!$G$6:$G$5005,"TEST_PAID",Requests!$E$6:$E$5005)+SUMIF(Requests!$G$6:$G$5005,"OWNER_CONFIRMED_TRANSFER_TEST",Requests!$E$6:$E$5005)');
  dash.getRange('A3').setValue('Synthetic demo activity. Automatic refresh about every minute. Counts include builder tests.');
  dash.getRange('A10').setValue('Last refresh (UTC): '+Utilities.formatDate(new Date(),'UTC','yyyy-MM-dd HH:mm:ss')+'; revision '+data.revision);
  dash.getRange('A12').setValue('Request totals exclude transport until quoted. Saved requests are not paid sales.');
  reconcileOwnerInputs_(ss,data);
  const queue=ss.getSheetByName('Owner follow-up');
  if(queue){const cases=data.followups||[];replaceRows_(queue,cases.map(c=>[c.id,c.request_id,text_(c.kind),text_(c.priority),text_(c.status),text_(JSON.stringify(c.details)),time_(c.created_at)]),7);if(cases.length){queue.getRange(6,6,cases.length,1).setWrap(true);queue.autoResizeRows(6,cases.length);}}
  const reviewSheet=ss.getSheetByName('Reviews');
  if(reviewSheet){
   const reviews=data.reviews||[];
   replaceRows_(reviewSheet,reviews.map(v=>[v.request_id,v.product_rating||'',v.service_rating||'',text_(v.product_feedback),text_(v.service_feedback),text_(v.overall_feedback),time_(v.updated_at)]),7);
   if(reviews.length){reviewSheet.getRange(6,4,reviews.length,3).setWrap(true);reviewSheet.autoResizeRows(6,reviews.length);}
  }
  PropertiesService.getScriptProperties().setProperty('LAST_SUCCESS',new Date().toISOString());
  SpreadsheetApp.flush();
 }catch(error){dash.getRange('A10').setValue('Refresh incomplete; last complete refresh: '+(PropertiesService.getScriptProperties().getProperty('LAST_SUCCESS')||'none'));throw error;}
 finally{lock.releaseLock();}
}
function setupDashboard() {
  const ss = spreadsheet_();
  let owner = ss.getSheetByName('Owner quotes');
  if (!owner) owner = ss.insertSheet('Owner quotes');

  owner.getRange('A1').setValue(
    'Owner input: transport quotes'
  );
  owner.getRange('A2').setValue(
    'Demo catalogue checks availability automatically. Enter the location-based fee: purchases = delivery; rentals = delivery + collection. Select row → Plant Loft → Save selected delivery quote. Customer then accepts the total before payment. Notifications need the configured Chord sender.'
  );
  owner.getRange('A5:E5').setValues([[
    'Request ID',
    'Transport fee (NGN)',
    'Driver / quote reference',
    'Expected version',
    'Result'
  ]]);

  owner.setFrozenRows(5);
  [310, 180, 240, 140, 420].forEach(
    (width, index) => owner.setColumnWidth(index + 1, width)
  );

  owner.getRange('A5:E5')
    .setBackground('#264C3B')
    .setFontColor('#ffffff')
    .setFontWeight('bold');
  owner.getRange('B6:D100').setBackground('#fff2cc');

  const exists = ScriptApp.getProjectTriggers().some(
    t => t.getHandlerFunction() === 'refreshDashboard'
  );
  if (!exists) {
    ScriptApp.newTrigger('refreshDashboard')
      .timeBased()
      .everyMinutes(1)
      .create();
  }

  setupLifecycleTabs_(ss);
  // The menu is installed by the Sheet open trigger, not editor execution.
  refreshDashboard();
}
function selectedRow_(tab,width){
 const ss=spreadsheet_(),sheet=ss.getActiveSheet(),range=sheet.getActiveRange();
 if(sheet.getName()!==tab||!range||range.getRow()<6||range.getNumRows()!==1)throw new Error('Select one populated row in '+tab);
 return {sheet:sheet,row:range.getRow(),values:sheet.getRange(range.getRow(),1,1,width).getValues()[0]};
}
function refreshAfterSave_(sheet,row,resultColumn,message){
 sheet.getRange(row,resultColumn).setValue(message);SpreadsheetApp.flush();
 try{refreshDashboard();}catch(error){sheet.getRange(row,resultColumn).setValue(message+' Dashboard refresh delayed; use Refresh dashboard.');}
}
function saveTransportQuote(){
 const lock=LockService.getUserLock();if(!lock.tryLock(5000))throw new Error('A save is already running');
 try{
  const x=selectedRow_('Owner quotes',4),[id,fee,reference,version]=x.values,kobo=Math.round(Number(fee)*100);
  if(!id||fee===''||!Number.isFinite(Number(fee))||!Number.isSafeInteger(kobo)||Math.abs(Number(fee)*100-kobo)>0.000001||!reference||version==='')throw new Error('Complete request ID, valid fee, reference and expected version');
  let r;try{r=ownerCall_('transport',{request_id:String(id),fee_kobo:kobo,owner_reference:String(reference),expected_version:Number(version)});}
  catch(error){x.sheet.getRange(x.row,5).setValue('Save not confirmed: '+error.message+'. Refresh before retry.');throw error;}
  x.sheet.getRange(x.row,4).setValue(r.summary.transport_version);
  refreshAfterSave_(x.sheet,x.row,5,'Saved. Total NGN '+Number(r.summary.final_total_kobo)/100+'. Customer must accept revised total.');
 }finally{lock.releaseLock();}
}
function confirmBankTransfer(){
 const x=selectedRow_('Owner payments',6),[id,amount,reference,version,verifier,received]=x.values,kobo=Math.round(Number(amount)*100);
 if(!id||amount===''||!Number.isFinite(Number(amount))||!Number.isSafeInteger(kobo)||Math.abs(Number(amount)*100-kobo)>0.000001||version===''||!reference||!verifier||received!==true)throw new Error('Enter request, exact received amount, bank reference, pricing version, verifier and tick funds received');
 const r=ownerCall_('confirm_transfer',{request_id:String(id),amount_kobo:kobo,bank_reference:String(reference),expected_version:Number(version),confirmed_by:String(verifier),funds_received:true});
 refreshAfterSave_(x.sheet,x.row,7,'Confirmed by owner bank check. '+r.summary.payment_status);
}
function saveFulfilment(){
 const x=selectedRow_('Owner fulfilment',3),[id,action,confirmed]=x.values;
 const names={DELIVERED:'delivered',RETURNED:'returned',APPROVE_STOCK:'approve_stock'};
 if(!id||!names[action]||confirmed!==true)throw new Error('Enter request ID, valid action and tick confirmation');
 const r=ownerCall_(names[action],{request_id:String(id),confirmed:true});
 refreshAfterSave_(x.sheet,x.row,4,'Saved. '+r.status);
}
function setupLifecycleTabs_(ss){
 const specifications=[
  ['Owner follow-up',['Case ID','Request ID','Reason','Priority','Status','Customer report / feedback','Reported (UTC)'],'Business follow-up queue: return claims are unconfirmed until collection is recorded; low ratings and complaints need owner attention. This queue is not a push notification.',[260,300,160,100,110,450,180]],
  ['Owner payments',['Request ID','Received amount (NGN)','Bank transaction reference','Expected pricing version','Verified by','Funds received','Result','Confirmed at (UTC)'],'Only confirm after checking the receiving bank. Enter the exact full amount; partial/overpayment goes to manual investigation. Select row → Plant Loft → Confirm selected bank transfer. Test data only.',[310,180,240,160,180,130,420,180]],
  ['Owner fulfilment',['Request ID','Action','Confirmed','Result'],'DELIVERED: sale delivered or rental in use. RETURNED: rental collected, completes rental. Stock is automatic in this demo; APPROVE_STOCK remains a legacy operator action. Select row → Plant Loft → Save selected fulfilment action.',[310,180,130,420]],
  ['Reviews',['Request ID','Product rating','Service rating','Product feedback','Service feedback','Overall feedback','Updated (UTC)'],'Customer feedback saved by the agent. Read-only output; ratings are optional and never inferred from text.',[310,130,130,300,300,300,180]]
 ];
 specifications.forEach(([name,headers,note,widths])=>{
  let sh=ss.getSheetByName(name);if(!sh)sh=ss.insertSheet(name);
  sh.getRange('A1').setValue(name);sh.getRange('A2').setValue(note);sh.getRange(5,1,1,headers.length).setValues([headers]).setBackground('#264C3B').setFontColor('#ffffff').setFontWeight('bold');sh.setFrozenRows(5);
  widths.forEach((w,i)=>sh.setColumnWidth(i+1,w));sh.getRange(2,1,1,headers.length).merge().setWrap(true);sh.setRowHeight(2,60);
 });
 const pay=ss.getSheetByName('Owner payments');pay.getRange('H6:H1000').setNumberFormat('yyyy-mm-dd hh:mm');pay.getRange('F6:F1000').setDataValidation(SpreadsheetApp.newDataValidation().requireCheckbox().build());pay.getRange('A6:F1000').setBackground('#fff2cc');
 const fulfil=ss.getSheetByName('Owner fulfilment');fulfil.getRange('B6:B1000').setDataValidation(SpreadsheetApp.newDataValidation().requireValueInList(['DELIVERED','RETURNED','APPROVE_STOCK'],true).setAllowInvalid(false).build());fulfil.getRange('C6:C1000').setDataValidation(SpreadsheetApp.newDataValidation().requireCheckbox().build());fulfil.getRange('A6:C1000').setBackground('#fff2cc');
 ss.getSheetByName('Owner follow-up').getRange('G6:G1000').setNumberFormat('yyyy-mm-dd hh:mm');
 ss.getSheetByName('Reviews').getRange('G6:G1000').setNumberFormat('yyyy-mm-dd hh:mm');
}
function reconcileOwnerInputs_(ss,data){
 const quotes=ss.getSheetByName('Owner quotes');
 if(quotes&&quotes.getLastRow()>=6){quotes.getRange(6,1,quotes.getLastRow()-5,5).getValues().forEach((v,i)=>{
  const r=data.requests.find(r=>r.id===String(v[0]));if(!r)return;
  if(v[1]!==''&&Math.round(Number(v[1])*100)===Number(r.summary.transport_fee_kobo)&&String(v[2])===r.summary.owner_quote_reference){
   quotes.getRange(i+6,4,1,2).setValues([[Number(r.summary.transport_version),'Saved. Total NGN '+Number(r.summary.final_total_kobo)/100+'. '+(r.summary.transport_accepted?'Customer accepted.':'Customer must accept revised total.')]]);
  }
 });}
 const pay=ss.getSheetByName('Owner payments');
 if(pay&&pay.getLastRow()>=6)pay.getRange(6,1,pay.getLastRow()-5,8).getValues().forEach((v,i)=>{const p=(data.receipts||[]).find(p=>p.request_id===String(v[0])&&p.bank_reference===String(v[2])&&p.amount_kobo===Math.round(Number(v[1])*100));if(p)pay.getRange(i+6,7,1,2).setValues([['Confirmed by owner bank check.',time_(p.created_at)]]);});
}
