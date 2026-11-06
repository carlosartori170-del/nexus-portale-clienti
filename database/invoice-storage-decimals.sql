CREATE OR REPLACE FUNCTION public.portal_tariff_quantity(p_quantities jsonb, p_rule jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
 basis text:=p_rule->>'basis';
 divisor numeric:=coalesce((p_rule->>'multiple')::numeric,1);
 fixed numeric:=coalesce((p_rule->>'per_order_pieces')::numeric,0);
 q numeric; orders numeric;
begin
 if divisor<1 or divisor<>trunc(divisor) then raise exception 'Multipli di deve essere un intero positivo';end if;
 if fixed<0 or fixed<>trunc(fixed) then raise exception 'Pezzi fissi per ordine non validi';end if;
 if fixed>0 and basis not in ('extra_pieces','shipped_pieces') then raise exception 'I pezzi fissi per ordine si applicano solo ai pezzi spediti';end if;
 if p_rule->>'mode'='included' then return 0;end if;
 if p_rule->>'mode'='fixed' then return 1;end if;
 q:=(p_quantities->>(case when basis='extra_pieces' then 'shipped_pieces' else basis end))::numeric;
 if q is null then return null;end if;
 if q<0 then raise exception 'Quantità non valida';end if;
 if fixed>0 or basis='extra_pieces' then
  orders:=(p_quantities->>'billable_shipments')::numeric;
  if orders is null then return null;end if;
  if orders<0 or orders<>trunc(orders) then raise exception 'Numero ordini non valido';end if;
 end if;
 if fixed>0 then
  q:=q-fixed*orders;
  if q<0 then raise exception 'Pezzi inferiori ai pezzi fissi previsti per gli ordini';end if;
 end if;
 if basis in ('extra_pieces','shipped_pieces','received_pieces','stock_pieces') then
  if mod(q,divisor)<>0 then raise exception 'Quantità non divisibile per il kit da % pezzi dopo l’esclusione dei pezzi fissi per ordine',divisor;end if;
  q:=q/divisor;
 end if;
 if basis='extra_pieces' then q:=q-orders;end if;
 if q<0 then raise exception 'I prodotti spediti non possono essere inferiori agli ordini spediti';end if;
 if basis='billable_m3' then q:=round(q,2);end if;
 return q;
end $function$
;
