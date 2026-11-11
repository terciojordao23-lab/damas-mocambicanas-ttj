// Damas Moçambicanas TTJ — authoritative move validation
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const dirs = [[-1,-1],[-1,1],[1,-1],[1,1]];
const inside = (r:number,c:number) => r>=0 && r<8 && c>=0 && c<8;
const clone = <T>(v:T):T => JSON.parse(JSON.stringify(v));
const forward = (color:string) => color === "white" ? -1 : 1;
const value = (p:any) => p?.king ? 3 : 2;

function pieceMoves(b:any[][],r:number,c:number,onlyCaptures=false,captured=new Set<string>()) {
  const p=b[r][c]; if(!p) return [] as any[];
  const out:any[]=[];
  if(p.king) {
    for(const [dr,dc] of dirs) {
      let rr=r+dr,cc=c+dc;
      while(inside(rr,cc)&&!b[rr][cc]) {
        if(!onlyCaptures) out.push({to:[rr,cc],cap:null});
        rr+=dr;cc+=dc;
      }
      if(inside(rr,cc)&&b[rr][cc].color!==p.color&&!captured.has(rr+","+cc)) {
        const cr=rr,ccap=cc; rr+=dr;cc+=dc;
        while(inside(rr,cc)&&!b[rr][cc]) {
          out.push({to:[rr,cc],cap:[cr,ccap]}); rr+=dr;cc+=dc;
        }
      }
    }
  } else {
    for(const [dr,dc] of dirs) {
      const rr=r+dr,cc=c+dc; if(!inside(rr,cc)) continue;
      if(!onlyCaptures&&dr===forward(p.color)&&!b[rr][cc]) out.push({to:[rr,cc],cap:null});
      if(b[rr][cc]&&b[rr][cc].color!==p.color&&!captured.has(rr+","+cc)) {
        const lr=rr+dr,lc=cc+dc;
        if(inside(lr,lc)&&!b[lr][lc]) out.push({to:[lr,lc],cap:[rr,cc]});
      }
    }
  }
  return out.filter(m=>onlyCaptures?!!m.cap:!m.cap);
}
function sequences(b:any[][],r:number,c:number,depth=0,previous:any=null,captured=new Set<string>()):any[] {
  const p=b[r][c]; if(!p) return [];
  const caps=pieceMoves(b,r,c,true,captured);
  if(!caps.length) return depth?[{moves:[],score:0}]:[];
  const all:any[]=[];
  for(const m of caps) {
    const d=[Math.sign(m.to[0]-r),Math.sign(m.to[1]-c)];
    if(p.king&&previous&&d[0]===-previous[0]&&d[1]===-previous[1]) continue;
    const key=m.cap[0]+","+m.cap[1]; if(captured.has(key)) continue;
    const nb=clone(b),moving=nb[r][c]; nb[r][c]=null; nb[m.to[0]][m.to[1]]=moving;
    const nextCaptured=new Set(captured); nextCaptured.add(key);
    let next=pieceMoves(nb,m.to[0],m.to[1],true,nextCaptured);
    if(moving.king) next=next.filter(x=>{
      const nd=[Math.sign(x.to[0]-m.to[0]),Math.sign(x.to[1]-m.to[1])];
      return !(nd[0]===-d[0]&&nd[1]===-d[1]);
    });
    let cont=next,promoted=false;
    const atEnd=!moving.king&&((moving.color==="white"&&m.to[0]===0)||(moving.color==="black"&&m.to[0]===7));
    if(atEnd) {
      cont=next.filter(x=>Math.abs(x.to[0]-m.to[0])===2&&Math.abs(x.to[1]-m.to[1])===2);
      if(!cont.length) promoted=true;
    }
    if(cont.length) {
      for(const tail of sequences(nb,m.to[0],m.to[1],depth+1,d,nextCaptured))
        all.push({moves:[{...m,promoteAfter:false},...tail.moves],score:value(b[m.cap[0]][m.cap[1]])+tail.score});
    } else all.push({moves:[{...m,promoteAfter:promoted||atEnd}],score:value(b[m.cap[0]][m.cap[1]])});
  }
  return all;
}
function allLegal(b:any[][],color:string) {
  const captures:any[]=[];
  for(let r=0;r<8;r++) for(let c=0;c<8;c++) if(b[r][c]?.color===color)
    for(const s of sequences(b,r,c)) if(s.moves.length) captures.push({from:[r,c],moves:s.moves,score:s.score});
  if(captures.length) {
    const max=Math.max(...captures.map(x=>x.score));
    return captures.filter(x=>x.score===max).sort((a,b)=>b.moves.length-a.moves.length);
  }
  const moves:any[]=[];
  for(let r=0;r<8;r++) for(let c=0;c<8;c++) if(b[r][c]?.color===color)
    for(const m of pieceMoves(b,r,c,false)) {
      const promotes=!b[r][c].king&&((color==="white"&&m.to[0]===0)||(color==="black"&&m.to[0]===7));
      moves.push({from:[r,c],moves:[{...m,promoteAfter:promotes}],score:0});
    }
  return moves;
}
function detectPG(b:any[][]) {
  const w=b.flat().filter(p=>p?.color==="white"), bl=b.flat().filter(p=>p?.color==="black");
  if(w.length===3&&w.every(p=>p.king)&&bl.length===1&&bl[0].king) return {hunter:"black",target:"white"};
  if(bl.length===3&&bl.every(p=>p.king)&&w.length===1&&w[0].king) return {hunter:"white",target:"black"};
  return null;
}
function same(a:any,b:any) { return JSON.stringify(a)===JSON.stringify(b); }

Deno.serve(async (req) => {
  if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
  if(req.method!=="POST") return json({error:"Método não permitido."},405);
  try {
    const url=Deno.env.get("SUPABASE_URL")!, anon=Deno.env.get("SUPABASE_ANON_KEY")!, service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const auth=req.headers.get("Authorization"); if(!auth) return json({error:"Sessão em falta."},401);
    const userClient=createClient(url,anon,{global:{headers:{Authorization:auth}}});
    const {data:{user},error:userError}=await userClient.auth.getUser();
    if(userError||!user) return json({error:"Sessão inválida."},401);
    const admin=createClient(url,service);
    const body=await req.json();
    const roomId=body?.room_id, expected=body?.expected_turn, path=body?.move_path, submitted=body?.board;
    if(typeof roomId!=="string"||!["white","black"].includes(expected)||!Array.isArray(path)||!path.length||path.length>24||!submitted)
      return json({error:"Dados da jogada incompletos."},400);

    const {data:room,error:readError}=await admin.from("rooms").select("*").eq("id",roomId).single();
    if(readError||!room) return json({error:"Sala não encontrada."},404);
    const color=user.id===room.host_id?"white":user.id===room.guest_id?"black":null;
    if(!color) return json({error:"Não pertences a esta sala."},403);
    if(room.status!=="playing"||room.current_turn!==expected||color!==expected)
      return json({error:"A partida não está disponível para esta jogada."},409);
    const prior=room.board;
    if(!prior?.B||prior.gameOver||prior.turn!==expected) return json({error:"Estado anterior inválido."},409);
    if(!Array.isArray(prior.B)||prior.B.length!==8||prior.B.some((row:any)=>!Array.isArray(row)||row.length!==8))
      return json({error:"Tabuleiro anterior inválido."},409);

    const legal=allLegal(prior.B,expected);
    const route=legal.find((candidate:any)=>candidate.moves.length===path.length&&same(candidate.from,path[0]?.from)&&candidate.moves.every((m:any,i:number)=>{
      const step=path[i]; return step&&same(m.to,step.to)&&same(m.cap,step.cap??null)&&m.promoteAfter===!!step.promoteAfter&&
        (i===0||same(path[i].from,path[i-1].to));
    }));
    if(!route) return json({error:"Jogada ilegal ou percurso de captura incompleto."},422);

    const nextBoard=clone(prior.B), captured:any[]=[];
    let pos=route.from.slice();
    for(const step of route.moves) {
      const moving=nextBoard[pos[0]][pos[1]];
      nextBoard[pos[0]][pos[1]]=null;
      if(step.cap) captured.push(step.cap);
      nextBoard[step.to[0]][step.to[1]]=moving;
      if(step.promoteAfter) moving.king=true;
      pos=step.to.slice();
    }
    for(const [r,c] of captured) nextBoard[r][c]=null;

    let gameOver=false, gameResult=null;
    let pgActive=!!prior.pgActive, pgHunter=prior.pgHunter??null, pgTarget=prior.pgTarget??null, pgMoves=Number(prior.pgMoves||0);
    const wasPG=pgActive;
    if(pgActive&&expected===pgHunter) {
      pgMoves++;
      const remaining=nextBoard.flat().filter(p=>p&&p.color===pgTarget).length;
      if(remaining===0) {gameOver=true;gameResult={type:"win",winnerColor:pgHunter,text:"Fim de jogo: o caçador venceu no Pé de Galinha."};}
      else if(pgMoves>=12) {gameOver=true;gameResult={type:"draw",winnerColor:null,text:"Empate: a dama sobreviveu às 12 jogadas do caçador no Pé de Galinha."};}
    }
    if(!wasPG&&!gameOver) {
      const pg=detectPG(nextBoard);
      if(pg) {pgActive=true;pgHunter=pg.hunter;pgTarget=pg.target;pgMoves=0;}
    }
    const nextTurn=expected==="white"?"black":"white";
    const nextLegal=allLegal(nextBoard,nextTurn);
    if(!gameOver&&!nextLegal.length) {
      gameOver=true;gameResult={type:"win",winnerColor:expected,text:"Fim de jogo: "+(expected==="white"?"jogador claro":"jogador escuro")+" venceu porque o adversário ficou sem jogadas."};
    }
    const expectedState={B:nextBoard,turn:nextTurn,gameOver,gameResult,pgActive,pgHunter,pgTarget,pgMoves};
    if(!same(submitted,expectedState)) return json({error:"O estado enviado não corresponde à jogada validada pelo servidor."},422);
    const winnerId=gameOver&&gameResult?.type==="win"?(gameResult.winnerColor==="white"?room.host_id:room.guest_id):null;
    const {data:updated,error:updateError}=await admin.from("rooms").update({
      board:expectedState,current_turn:nextTurn,status:gameOver?"finished":"playing",winner_id:winnerId,updated_at:new Date().toISOString()
    }).eq("id",roomId).eq("current_turn",expected).eq("status","playing").select("id").maybeSingle();
    if(updateError) throw updateError;
    if(!updated) return json({error:"A partida foi actualizada por outra operação. Recupera o estado mais recente."},409);
    return json({success:true,status:gameOver?"finished":"playing",winner_id:winnerId});
  } catch(e) {
    console.error(e);
    return json({error:e instanceof Error?e.message:"Erro interno ao validar a jogada."},500);
  }
});
