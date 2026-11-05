-- Execute after applying database/order-kit-pieces.sql. Synthetic input only.
do $test$
declare p integer; result numeric;
begin
 foreach p in array array[5,9,13] loop
  result:=public.portal_tariff_quantity(jsonb_build_object('shipped_pieces',p,'billable_shipments',1),'{"basis":"extra_pieces","mode":"unit","multiple":4,"per_order_pieces":1}');
  assert result=(p-1)/4-1, 'Quantità dal secondo occhiale errata';
 end loop;
 assert public.portal_tariff_quantity('{"shipped_pieces":27,"billable_shipments":3}','{"basis":"extra_pieces","mode":"unit","multiple":4,"per_order_pieces":1}')=3;
 assert public.portal_tariff_quantity('{"shipped_pieces":15,"billable_shipments":2}','{"basis":"extra_pieces","mode":"unit","multiple":5}')=1;
 assert public.portal_tariff_quantity('{"received_pieces":20}','{"basis":"received_pieces","mode":"unit","multiple":5}')=4;
 assert public.portal_tariff_quantity('{"shipped_pieces":0,"billable_shipments":0}','{"basis":"extra_pieces","mode":"unit","multiple":4,"per_order_pieces":1}')=0;
 begin
  perform public.portal_tariff_quantity('{"shipped_pieces":8,"billable_shipments":1}','{"basis":"extra_pieces","mode":"unit","multiple":4,"per_order_pieces":1}');
  raise exception 'Il kit incompleto doveva essere rifiutato' using errcode='XX000';
 exception when raise_exception then null;
 end;
end $test$;
