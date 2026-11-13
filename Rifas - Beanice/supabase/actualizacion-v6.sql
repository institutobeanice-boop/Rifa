-- =====================================================================
--  ACTUALIZACIÓN v6: Aceptar el comprobante aunque la reserva haya vencido
--  Si el cliente transfirió tarde, se le asignan números nuevos al azar
--  y la orden vuelve a "pendiente" para que la verifiques.
--  Ejecuta TODO este archivo en Supabase > SQL Editor > New query > Run
-- =====================================================================
create or replace function public.attach_receipt(p_order_id uuid, p_path text, p_bank text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.orders; r public.raffles; v_got int;
begin
  select * into o from public.orders where id = p_order_id for update;
  if o.id is null or o.payment_method <> 'transfer' then raise exception 'No encontramos esta orden'; end if;
  if o.status = 'paid' then raise exception 'Esta orden ya fue confirmada. Revisa tus números en el Verificador.'; end if;
  if o.status not in ('pending','expired') then
    raise exception 'Esta orden fue cancelada o rechazada. Escríbenos por WhatsApp con tu captura.'; end if;

  -- Reserva vencida: asignar números nuevos al azar (los anteriores pudieron venderse)
  if not exists (select 1 from public.tickets where order_id = o.id) then
    select * into r from public.raffles where id = o.raffle_id;
    if r.status not in ('active','closed') then
      raise exception 'Esta rifa ya fue sorteada. Escríbenos por WhatsApp con tu captura.'; end if;
    with picked as (
      select id from public.tickets where raffle_id = r.id and status = 'available'
       order by random() limit o.quantity for update skip locked)
    update public.tickets t set status = 'reserved', order_id = o.id, reserved_until = now() + interval '72 hours'
      from picked where t.id = picked.id;
    get diagnostics v_got = row_count;
    if v_got < o.quantity then
      raise exception 'Ya no quedan suficientes números disponibles. Escríbenos por WhatsApp con tu captura.'; end if;
    update public.orders set status = 'pending',
      response_msg = 'REVISAR: comprobante enviado después de vencer la reserva (números reasignados)'
     where id = o.id;
  end if;

  update public.orders set receipt_path = p_path, bank_account = left(p_bank, 120) where id = o.id;
  update public.tickets set reserved_until = now() + interval '72 hours' where order_id = o.id and status = 'reserved';
end $$;
revoke execute on function public.attach_receipt(uuid,text,text) from public, anon, authenticated;

notify pgrst, 'reload schema';
