-- Damas Moçambicanas TTJ
-- Secure room creation and move synchronization.
-- Apply in Supabase SQL Editor only after reviewing this migration.

CREATE OR REPLACE FUNCTION public.create_game_room_with_board(p_board jsonb)
RETURNS TABLE(room_id uuid, room_code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  new_code text;
  new_id uuid;
  r integer;
  c integer;
  expected_board jsonb := '[]'::jsonb;
  expected_row jsonb;
  expected_cell jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'É necessário iniciar uma sessão.';
  END IF;

  IF jsonb_typeof(p_board) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Estado inicial do tabuleiro inválido.';
  END IF;

  IF jsonb_typeof(p_board->'B') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Estado inicial do tabuleiro inválido.';
  END IF;

  IF jsonb_array_length(p_board->'B') <> 8
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(p_board->'B') AS board_row(value)
       WHERE CASE
         WHEN jsonb_typeof(board_row.value) = 'array'
           THEN jsonb_array_length(board_row.value)
         ELSE -1
       END <> 8
     )
     OR p_board->>'turn' IS DISTINCT FROM 'white'
     OR p_board->>'gameOver' IS DISTINCT FROM 'false'
     OR p_board->'gameResult' IS DISTINCT FROM 'null'::jsonb
     OR p_board->'pgActive' IS DISTINCT FROM 'false'::jsonb
     OR p_board->'pgHunter' IS DISTINCT FROM 'null'::jsonb
     OR p_board->'pgTarget' IS DISTINCT FROM 'null'::jsonb
     OR p_board->'pgMoves' IS DISTINCT FROM '0'::jsonb THEN
    RAISE EXCEPTION 'Estado inicial do tabuleiro inválido.';
  END IF;

  -- Only the standard 12-versus-12 starting position is accepted for a new room.
  FOR r IN 0..7 LOOP
    expected_row := '[]'::jsonb;
    FOR c IN 0..7 LOOP
      IF (r + c) % 2 = 0 AND r < 3 THEN
        expected_cell := jsonb_build_object('color', 'black', 'king', false);
      ELSIF (r + c) % 2 = 0 AND r >= 5 THEN
        expected_cell := jsonb_build_object('color', 'white', 'king', false);
      ELSE
        expected_cell := 'null'::jsonb;
      END IF;
      expected_row := expected_row || jsonb_build_array(expected_cell);
    END LOOP;
    expected_board := expected_board || jsonb_build_array(expected_row);
  END LOOP;

  IF p_board->'B' IS DISTINCT FROM expected_board THEN
    RAISE EXCEPTION 'A sala deve começar com a posição normal de 12 peças por jogador.';
  END IF;

  LOOP
    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.rooms r WHERE r.code = new_code
    );
  END LOOP;

  INSERT INTO public.rooms (code, host_id, board, current_turn, status)
  VALUES (new_code, auth.uid(), p_board, 'white', 'waiting')
  RETURNING id INTO new_id;

  RETURN QUERY SELECT new_id, new_code;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_game_room(
  p_room_id uuid,
  p_board jsonb,
  p_expected_turn text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_room record;
  v_actor_color text;
  v_next_turn text;
  v_finished boolean;
  v_winner_id uuid;
  v_winner_color text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Utilizador não autenticado.';
  END IF;

  IF p_expected_turn IS NULL
     OR p_expected_turn NOT IN ('white', 'black')
     OR jsonb_typeof(p_board) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Estado da jogada inválido.';
  END IF;

  IF jsonb_typeof(p_board->'B') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Estado da jogada inválido.';
  END IF;

  IF jsonb_array_length(p_board->'B') <> 8
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(p_board->'B') AS board_row(value)
       WHERE CASE
         WHEN jsonb_typeof(board_row.value) = 'array'
           THEN jsonb_array_length(board_row.value)
         ELSE -1
       END <> 8
     )
     OR p_board->>'turn' IS NULL
     OR p_board->>'turn' NOT IN ('white', 'black')
     OR jsonb_typeof(p_board->'gameOver') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'Estado da jogada inválido.';
  END IF;

  SELECT id, host_id, guest_id, status, current_turn
  INTO v_room
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sala não encontrada.';
  END IF;

  IF auth.uid() = v_room.host_id THEN
    v_actor_color := 'white';
  ELSIF auth.uid() = v_room.guest_id THEN
    v_actor_color := 'black';
  ELSE
    RAISE EXCEPTION 'Não pertences a esta sala.';
  END IF;

  IF v_room.status <> 'playing' THEN
    RAISE EXCEPTION 'Esta partida não está em curso.';
  END IF;

  IF v_room.current_turn <> p_expected_turn
     OR v_actor_color <> p_expected_turn THEN
    RAISE EXCEPTION 'Não é a tua vez de jogar ou o estado ficou desactualizado.';
  END IF;

  v_next_turn := p_board->>'turn';
  v_finished := (p_board->>'gameOver')::boolean;

  IF NOT v_finished AND v_next_turn = p_expected_turn THEN
    RAISE EXCEPTION 'A vez seguinte não corresponde ao estado enviado.';
  END IF;

  IF v_finished AND p_board#>>'{gameResult,type}' = 'win' THEN
    v_winner_color := p_board#>>'{gameResult,winnerColor}';
    IF v_winner_color = 'white' THEN
      v_winner_id := v_room.host_id;
    ELSIF v_winner_color = 'black' THEN
      v_winner_id := v_room.guest_id;
    ELSE
      RAISE EXCEPTION 'Cor do vencedor inválida.';
    END IF;
  END IF;

  UPDATE public.rooms
  SET board = p_board,
      current_turn = v_next_turn,
      status = CASE WHEN v_finished THEN 'finished' ELSE 'playing' END,
      winner_id = v_winner_id,
      updated_at = now()
  WHERE id = p_room_id;

  RETURN jsonb_build_object(
    'success', true,
    'status', CASE WHEN v_finished THEN 'finished' ELSE 'playing' END,
    'winner_id', v_winner_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.create_game_room_with_board(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_game_room_with_board(jsonb) TO authenticated;

-- The browser must not call the legacy client-supplied-board RPC.
-- Online moves are validated and written only by the Edge Function using service_role.
REVOKE ALL ON FUNCTION public.sync_game_room(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;

-- Resignation is authenticated and participant-checked inside the SECURITY DEFINER RPC.
-- Anonymous API roles must not be able to invoke it without an authenticated session.
REVOKE ALL ON FUNCTION public.resign_game_room(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resign_game_room(uuid) TO authenticated;
