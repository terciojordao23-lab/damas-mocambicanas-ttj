-- Integration checks for the migration, executed against disposable PostgreSQL in CI.
DO $$
DECLARE
  v_board jsonb;
  v_room record;
  v_pieces integer;
  v_rejected boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  SELECT jsonb_build_object(
    'B', (
      SELECT jsonb_agg(row_data ORDER BY r)
      FROM (
        SELECT r, jsonb_agg(
          CASE
            WHEN (r+c) % 2 = 0 AND r < 3
              THEN jsonb_build_object('color','black','king',false)
            WHEN (r+c) % 2 = 0 AND r >= 5
              THEN jsonb_build_object('color','white','king',false)
            ELSE 'null'::jsonb
          END ORDER BY c
        ) AS row_data
        FROM generate_series(0,7) AS r
        CROSS JOIN generate_series(0,7) AS c
        GROUP BY r
      ) rows_data
    ),
    'turn','white',
    'gameOver',false,
    'gameResult',null,
    'pgActive',false,
    'pgHunter',null,
    'pgTarget',null,
    'pgMoves',0
  ) INTO v_board;

  SELECT * INTO v_room
  FROM public.create_game_room_with_board(v_board);

  IF v_room.room_id IS NULL OR v_room.room_code IS NULL OR length(v_room.room_code) <> 6 THEN
    RAISE EXCEPTION 'RPC did not return a valid room id and six-character code';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.rooms
    WHERE id=v_room.room_id
      AND host_id='11111111-1111-4111-8111-111111111111'::uuid
      AND status='waiting'
      AND current_turn='white'
      AND board=v_board
  ) THEN
    RAISE EXCEPTION 'Room was not inserted with the expected initial state';
  END IF;

  SELECT count(*) INTO v_pieces
  FROM jsonb_array_elements(v_board->'B') AS row_data(value)
  CROSS JOIN LATERAL jsonb_array_elements(row_data.value) AS cell(value)
  WHERE jsonb_typeof(cell.value)='object';
  IF v_pieces <> 24 THEN RAISE EXCEPTION 'Expected 24 initial pieces, got %', v_pieces; END IF;

  BEGIN
    PERFORM * FROM public.create_game_room_with_board(
      jsonb_set(v_board, '{turn}', '"black"'::jsonb)
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Invalid initial board was accepted'; END IF;

  IF NOT has_function_privilege('authenticated','public.create_game_room_with_board(jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'authenticated cannot execute room creation RPC';
  END IF;
  IF has_function_privilege('authenticated','public.sync_game_room(uuid,jsonb,text)','EXECUTE')
     OR has_function_privilege('anon','public.sync_game_room(uuid,jsonb,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Legacy client-supplied-board sync RPC is still executable';
  END IF;
END $$;
