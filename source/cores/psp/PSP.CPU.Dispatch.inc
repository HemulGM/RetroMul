  // Compiled into each loop: no per-instruction mode/counter branch.
  while (C.FRemaining > 0){$IFDEF PSP_DISPATCH_STEPS} and (Steps > 0){$ENDIF} do
  begin
    var PC := C.Ctx.PC;
    var Entry := C.Decoded(PC);
    C.CurPC := PC;
    C.Ctx.PC := C.Ctx.NPC;
    C.Ctx.NPC := C.Ctx.NPC + 4;
    Dec(C.FRemaining);
{$IF DEFINED(PSP_DISPATCH_STEPS) or DEFINED(PSP_DISPATCH_COUNT)}
    Inc(FInterpreted);
{$ENDIF}
    Entry.Handler(C, Entry.Op);
    if C.Stopping then
      Break;
{$IFDEF PSP_DISPATCH_STEPS}
    Dec(Steps);
{$ENDIF}
  end;
