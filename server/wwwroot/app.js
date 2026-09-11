const q=id=>document.getElementById(id);
const esc=value=>String(value??'').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
function formatSeen(value){if(!value)return 'ещё не получен';const date=new Date(value);return isNaN(date)?value:date.toLocaleString('ru-RU')}
async function api(url,options){const response=await fetch(url,{cache:'no-store',...options});if(response.status===401){location.href='/login.html';throw new Error('Требуется вход');}if(!response.ok)throw new Error(await response.text());return response.json()}
function renderAgents(items){
  const online=items.filter(x=>x.online).length;
  const jobs=items.reduce((sum,x)=>sum+(x.report?.jobs?.length||0),0);
  q('agentsTotal').textContent=items.length;q('agentsOnline').textContent=online;q('agentsOffline').textContent=items.length-online;q('jobsTotal').textContent=jobs;
  q('agents').innerHTML=items.length?items.map(agent=>`<article class="agent ${agent.online?'online':'offline'}"><div class="agent-head"><div><span class="status-dot"></span><strong>${esc(agent.displayName||agent.host)}</strong><small>${agent.online?'Подключён':'Нет связи'}</small></div><span class="version">Agent ${esc(agent.version||'—')}</span></div><dl><div><dt>Host</dt><dd>${esc(agent.host||'—')}</dd></div><div><dt>Последняя связь</dt><dd>${esc(formatSeen(agent.lastSeen))}</dd></div><div><dt>Базы</dt><dd>${agent.report?.jobs?.length||0}</dd></div><div><dt>Локальные файлы</dt><dd>${(agent.report?.jobs||[]).reduce((s,j)=>s+(j.fileCount||0),0)}</dd></div></dl></article>`).join(''):'<div class="empty">Агенты ещё не подключены.</div>';
}
async function refresh(){q('refresh').disabled=true;try{const [server,data,health]=await Promise.all([api('/api/server'),api('/api/agents'),api('/api/health')]);q('enrollmentCode').textContent=server.enrollmentCode;q('hostBadge').textContent=`● ${health.host} · v${health.version}`;renderAgents(data.agents||[])}finally{q('refresh').disabled=false}}
q('copyCode').onclick=async()=>{await navigator.clipboard.writeText(q('enrollmentCode').textContent);q('copyCode').textContent='Скопировано';setTimeout(()=>q('copyCode').textContent='Копировать',1200)};
q('refresh').onclick=refresh;q('logout').onclick=async()=>{await fetch('/api/logout',{method:'POST'});location.href='/login.html'};
refresh();setInterval(refresh,15000);
