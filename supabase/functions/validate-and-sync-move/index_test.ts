import { allLegal, detectPG, same } from "./index.ts";

function emptyBoard(): any[][] {
  return Array.from({ length: 8 }, () => Array(8).fill(null));
}

Deno.test("posição inicial produz 12 peças por lado e movimentos claros legais", () => {
  const b = emptyBoard();
  for (let r = 0; r < 3; r++) for (let c = 0; c < 8; c++)
    if ((r + c) % 2 === 0) b[r][c] = { color: "black", king: false };
  for (let r = 5; r < 8; r++) for (let c = 0; c < 8; c++)
    if ((r + c) % 2 === 0) b[r][c] = { color: "white", king: false };
  if (b.flat().filter(p => p?.color === "white").length !== 12) throw new Error("white count");
  if (b.flat().filter(p => p?.color === "black").length !== 12) throw new Error("black count");
  if (allLegal(b, "white").length !== 7) throw new Error("expected 7 legal opening moves");
});

Deno.test("dama captura à distância e pode escolher qualquer casa livre depois da peça", () => {
  const b = emptyBoard();
  b[6][0] = { color: "white", king: true };
  b[3][3] = { color: "black", king: false };
  const legal = allLegal(b, "white");
  const landings = legal.map(x => x.moves[0].to).filter((p:any[]) => p[0] === 2 || p[0] === 1 || p[0] === 0);
  if (landings.length !== 3) throw new Error("expected 3 landing squares");
  if (!landings.some((p:any[]) => same(p, [2,4])) ||
      !landings.some((p:any[]) => same(p, [1,5])) ||
      !landings.some((p:any[]) => same(p, [0,6])) )
    throw new Error("unexpected flying-king landing squares");
});

Deno.test("captura de maior valor prevalece sobre captura de menor valor", () => {
  const b = emptyBoard();
  b[4][0] = { color: "white", king: false };
  b[4][4] = { color: "white", king: false };
  b[3][1] = { color: "black", king: false };
  b[1][3] = { color: "black", king: true };
  b[3][5] = { color: "black", king: false };
  const legal = allLegal(b, "white");
  if (!legal.length || legal.some(x => !same(x.from, [4,0])))
    throw new Error("lower-value capture route was not excluded");
  if (legal[0].score !== 5) throw new Error("expected man + king value 5");
});

Deno.test("dado que chega à promoção durante captura múltipla promove no fim da sequência", () => {
  const b = emptyBoard();
  b[2][2] = { color: "white", king: false };
  b[1][3] = { color: "black", king: false };
  b[1][5] = { color: "black", king: false };
  const legal = allLegal(b, "white");
  const route = legal.find(x => same(x.from, [2,2]));
  if (!route || route.moves.length !== 2) throw new Error("expected a two-capture route");
  if (!same(route.moves[0].to, [0,4]) || route.moves[0].promoteAfter)
    throw new Error("man should continue the sequence without crowning immediately");
  if (!same(route.moves[1].to, [2,6]) || !route.moves[1].promoteAfter)
    throw new Error("man should be crowned after the final capture");
});

Deno.test("Pé de Galinha detecta correctamente três damas contra uma", () => {
  const b = emptyBoard();
  b[6][0] = { color: "white", king: true };
  b[4][2] = { color: "white", king: true };
  b[6][4] = { color: "white", king: true };
  b[2][6] = { color: "black", king: true };
  if (!same(detectPG(b), { hunter: "white", target: "black" }))
    throw new Error("wrong hunter/target");
});

Deno.test("comparação de estados ignora ordem das propriedades JSON", () => {
  if (!same({ a: 1, b: { c: 2, d: 3 } }, { b: { d: 3, c: 2 }, a: 1 }))
    throw new Error("canonical comparison failed");
});
