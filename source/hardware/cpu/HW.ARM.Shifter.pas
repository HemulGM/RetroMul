unit HW.ARM.Shifter;

// Shared ARM barrel shifter used by the DC ARM7DI and GBA ARM7TDMI cores.
// Count is the decoded immediate (0..31) or low byte of a register (0..255).
// Carry is both the input carry for RRX/zero shifts and the output carry.

interface

function ARMRotateRight(Value: Cardinal; Count: Integer): Cardinal; inline;

function ARMShift(Value: Cardinal; Kind, Count: Integer; Immediate: Boolean; var Carry: Cardinal): Cardinal;

implementation

function ARMRotateRight(Value: Cardinal; Count: Integer): Cardinal; inline;
begin
  Count := Count and 31;
  if Count = 0 then
    Result := Value
  else
    Result := (Value shr Count) or (Value shl (32 - Count));
end;

function ARMShift(Value: Cardinal; Kind, Count: Integer; Immediate: Boolean; var Carry: Cardinal): Cardinal;
begin
  Result := Value;
  if (Count = 0) and not Immediate then
    Exit;

  case Kind of
    0:
      begin
        if Count = 0 then
          Exit;
        if Count <= 32 then
          Carry := (Value shr (32 - Count)) and 1
        else
          Carry := 0;
        if Count < 32 then
          Result := Value shl Count
        else
          Result := 0;
      end;
    1:
      begin
        if Count = 0 then
          Count := 32;
        if Count <= 32 then
          Carry := (Value shr (Count - 1)) and 1
        else
          Carry := 0;
        if Count < 32 then
          Result := Value shr Count
        else
          Result := 0;
      end;
    2:
      begin
        if Count = 0 then
          Count := 32;
        if Count < 32 then
        begin
          Carry := (Value shr (Count - 1)) and 1;
          Result := Value shr Count;
          if Value and $80000000 <> 0 then
            Result := Result or ($FFFFFFFF shl (32 - Count));
        end
        else
        begin
          Carry := Value shr 31;
          Result := 0;
          if Carry <> 0 then
            Result := $FFFFFFFF;
        end;
      end;
    3:
      begin
        if (Count = 0) and Immediate then
        begin
          Result := (Carry shl 31) or (Value shr 1);
          Carry := Value and 1;
        end
        else
        begin
          Result := ARMRotateRight(Value, Count);
          Carry := Result shr 31;
        end;
      end;
  end;
end;

end.

