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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'É necessário iniciar uma sessão.';
  END IF;

  IF jsonb_typeof(p_board) <> 'object'
     OR jsonb_typeof(p_board->'B') <> 'array'
     OR p_board->>'turn' <> 'white'
     OR COALESCE((p_board->>'gameOver')::boolean, true) THEN
    RAISE EXCEPTION 'Estado inicial do tabuleiro inválido.';
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

  IF p_expected_turn NOT IN ('white', 'black')
     OR jsonb_typeof(p_board) <> 'object'
     OR jsonb_typeof(p_board->'B') <> 'array'
     OR p_board->>'turn' NOT IN ('white', 'black')
     OR jsonb_typeof(p_board->'gameOver') <> 'boolean' THEN
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

REVOKE ALL ON FUNCTION public.sync_game_room(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_game_room(uuid, jsonb, text) TO authenticated;
