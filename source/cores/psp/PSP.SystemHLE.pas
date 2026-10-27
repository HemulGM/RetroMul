unit PSP.SystemHLE;

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Memory, PSP.CPU, PSP.Kernel;

type
  TPSPAdhocHandler = record
    Entry, Argument: Cardinal;
  end;

  TPSPSystemHLE = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FLanguage, FButtonMode, FBacklight, FUMDPopup: Cardinal;
    FAdhocChannel, FWlanPowerSave: Cardinal;
    FUMDReplacePermit: Boolean;
    FCPUClock, FBusClock, FPLLClock: Cardinal;
    FPowerCallbacks: array[0..15] of Cardinal;
    FUMDCallback: Cardinal;
    FUMDPresent, FUMDActive: Boolean;
    FTickBase: UInt64;
    FClockBase: TDateTime;
    FModules: TDictionary<Cardinal, Boolean>;
    FPowerLocks: Cardinal;
    FPowerTick: UInt64;
    FLicenseKey: array[0..15] of Byte;
    FHasLicenseKey: Boolean;
    FNetBlocks: array[0..2] of Cardinal;
    FNetPoolSize: Cardinal;
    FAdhocInitialized, FMatchingInitialized: Boolean;
    FMatchingBlock, FMatchingPoolSize: Cardinal;
    FAdhocctlInitialized: Boolean;
    FAdhocctlBlock: Cardinal;
    FAdhocctlProduct: TBytes;
    FAdhocctlHandlers: TDictionary<Cardinal,TPSPAdhocHandler>;
    procedure ReleaseNet;
    procedure ReleaseMatching;
    procedure ReleaseAdhocctl;
    function Adhoc(const ModuleName: string; NID, A, B, C: Cardinal; out Value: Cardinal): Boolean;
    function Net(NID, A, B, C, D: Cardinal; out Value: Cardinal): Boolean;
    function RTC(NID, A, B, C: Cardinal; out Value: Cardinal): Boolean;
    procedure WriteTick(Address: Cardinal; Tick: UInt64);
    procedure WriteClock(Address: Cardinal; Clock: TDateTime);
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel; UMDPresent: Boolean);
    destructor Destroy; override;
    function Handle(const ModuleName: string; NID: Cardinal; out Value: Cardinal): Boolean;
  end;

implementation

uses
  System.DateUtils;

constructor TPSPSystemHLE.Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel; UMDPresent: Boolean);
begin
  inherited Create;
  FMemory := Memory;
  FModules := TDictionary<Cardinal, Boolean>.Create;
  FAdhocctlHandlers:=TDictionary<Cardinal,TPSPAdhocHandler>.Create;
  FCPU := CPU;
  FKernel := Kernel;
  FLanguage := 1;
  FButtonMode := 1;
  FCPUClock := 222;
  FKernel.CPUClock := FCPUClock;
  FBusClock := 111;
  FPLLClock := 222;
  FUMDPresent := UMDPresent;
  FUMDActive := UMDPresent;
  FUMDPopup := 1;
  FWlanPowerSave := 1;
  FUMDReplacePermit := True;
  FClockBase := TTimeZone.local.ToUniversalTime(Now);
  FTickBase := Round((FClockBase - EncodeDate(1, 1, 1)) * 86400000000.0);
end;

destructor TPSPSystemHLE.Destroy;
begin
  ReleaseNet;
  FAdhocctlHandlers.Free;
  FModules.Free;
  inherited;
end;

procedure TPSPSystemHLE.ReleaseNet;
begin
  ReleaseAdhocctl;
  ReleaseMatching;
  FAdhocInitialized:=False;
  for var I := 0 to 2 do
    if FNetBlocks[I] <> 0 then
    begin
      FKernel.ReleaseModule(FNetBlocks[I]);
      FNetBlocks[I] := 0
    end;
  FNetPoolSize := 0;
end;

procedure TPSPSystemHLE.ReleaseMatching;
begin
  if FMatchingBlock<>0 then FKernel.ReleaseModule(FMatchingBlock);
  FMatchingBlock:=0;
  FMatchingPoolSize:=0;
  FMatchingInitialized:=False;
end;

procedure TPSPSystemHLE.ReleaseAdhocctl;
begin
  if FAdhocctlBlock<>0 then FKernel.ReleaseModule(FAdhocctlBlock);
  FAdhocctlBlock:=0;
  FAdhocctlInitialized:=False;
  FAdhocctlProduct:=nil;
  if FAdhocctlHandlers<>nil then FAdhocctlHandlers.Clear;
end;

function TPSPSystemHLE.Adhoc(const ModuleName: string; NID, A, B, C: Cardinal; out Value: Cardinal): Boolean;
begin
  Result:=True;Value:=0;
  if ModuleName='sceNetAdhoc' then
  begin
    case NID of
      $E1D621D7:
        if FAdhocInitialized then Value:=$80410713
        else FAdhocInitialized:=True;
      $A62C6F57:
        begin ReleaseAdhocctl;ReleaseMatching;FAdhocInitialized:=False end;
    else Result:=False end;
    Exit;
  end;
  if ModuleName='sceNetAdhocctl' then
  begin
    if NID=$E26F226E then
    begin
      if FAdhocctlInitialized then begin Value:=$80410B07;Exit end;
      if (C<>0) and not FMemory.IsValid(C,13) then begin Value:=$80410B04;Exit end;
      if (B<8) or (B>119) then begin Value:=$80020193;Exit end;
      if A>PSPRAMSize then begin Value:=$80020190;Exit end;
      var Size:=A;if Size<$200 then Size:=$200;
      var Address:Cardinal;var Block:=FKernel.ReserveModule(Size,Address);
      if Block and $80000000<>0 then begin Value:=Block;Exit end;
      FAdhocctlBlock:=Block;
      FMemory.Zero(Address,Size);
      SetLength(FAdhocctlProduct,16);
      if C<>0 then FMemory.ReadInto(C,13,FAdhocctlProduct);
      FAdhocctlInitialized:=True;
      Exit;
    end;
    if NID=$9D689E13 then begin ReleaseAdhocctl;Exit end;
    case NID of
      $20B317A0,$6402490B,$75ECD386,$362CBE8F,$DED9D28E,$81AEE1BE,$E162CB14,
      $34401D65,$0AD043ED,$EC0635C1,$08FFF7A0,$5E7F79C9:;
    else Exit(False) end;
    if not FAdhocctlInitialized then begin Value:=$80410B08;Exit end;
    case NID of
      $20B317A0:
        begin
          if (A and 3<>0) or not FMemory.IsValid(A,4) then begin Value:=$80410B04;Exit end;
          // PSP handler IDs occupy 0..3 (also used by Jpcsp's UID range).
          if FAdhocctlHandlers.Count>=4 then begin Value:=$80410B12;Exit end;
          while FAdhocctlHandlers.ContainsKey(Value) do Inc(Value);
          var Handler:TPSPAdhocHandler;Handler.Entry:=A;Handler.Argument:=B;
          FAdhocctlHandlers.Add(Value,Handler);
        end;
      $6402490B:FAdhocctlHandlers.Remove(A);
      $75ECD386:
        if not FMemory.IsValid(A,4) then Value:=$80410B04
        else FMemory.Write32(A,0); // Disconnected while the WLAN switch is off.
      $362CBE8F:
        if not FMemory.IsValid(A,16) then Value:=$80410B04
        else FMemory.Load(A,FAdhocctlProduct);
      $DED9D28E:Value:=$80410B09;
      $81AEE1BE,$E162CB14:
        if not FMemory.IsValid(A,4) then Value:=$80410B04
        else FMemory.Write32(A,0); // No scan results or peers exist offline.
      $34401D65:; // Already disconnected; there is no transition to report.
      $0AD043ED,$EC0635C1,$08FFF7A0,$5E7F79C9:Value:=$80410B03;
    end;
    Exit;
  end;
  if ModuleName<>'sceNetAdhocMatching' then Exit(False);
  case NID of
    $2A2A1E07:
      begin
        if FMatchingInitialized then begin Value:=$80410812;Exit end;
        if A>PSPRAMSize then begin Value:=$80410809;Exit end;
        if A<>0 then
        begin
          var Address:Cardinal;
          var Block:=FKernel.ReserveModule(A,Address);
          if Block and $80000000<>0 then begin Value:=$80410809;Exit end;
          FMatchingBlock:=Block;
          FMemory.Zero(Address,A);
        end;
        FMatchingPoolSize:=A;
        FMatchingInitialized:=True;
      end;
    $7945ECDA:ReleaseMatching;
    $40F8F435,$9C5CFB7D:
      begin
        if not FMatchingInitialized then begin Value:=$80410813;Exit end;
        if NID=$40F8F435 then begin Value:=FMatchingPoolSize;Exit end;
        if not FMemory.IsValid(A,12) then begin Value:=$80410806;Exit end;
        FMemory.Write32(A,FMatchingPoolSize);
        FMemory.Write32(A+4,0);
        FMemory.Write32(A+8,FMatchingPoolSize);
      end;
  else Result:=False end;
end;

function TPSPSystemHLE.Net(NID, A, B, C, D: Cardinal; out Value: Cardinal): Boolean;

  function Hex(C: Char): Integer;
  begin
    case C of
      '0'..'9':
        Result := Ord(C) - Ord('0');
      'a'..'f':
        Result := Ord(C) - Ord('a') + 10;
      'A'..'F':
        Result := Ord(C) - Ord('A') + 10;
    else
      Result := -1
    end;
  end;

begin
  Result := True;
  Value := 0;
  case NID of
    $39AF39A6:
      begin
        if (A < 32) or (A > PSPRAMSize) then
        begin
          Value := $800201B7;
          Exit
        end;
        if (B < 8) or (B > $77) or (D < 8) or (D > $77) then
        begin
          Value := $80020193;
          Exit
        end;
        ReleaseNet;
        for var I := 0 to 2 do
        begin
          var Size: Cardinal := 4096;
          if I = 2 then
            Size := A;
          var Address: Cardinal;
          var Block := FKernel.ReserveModule(Size, Address, False);
          if Block and $80000000 <> 0 then
          begin
            ReleaseNet;
            Value := Block;
            Exit
          end;
          FNetBlocks[I] := Block;
          FMemory.Zero(Address, Size);
        end;
        FNetPoolSize := A - 32;
      end;
    $281928A9:
      ReleaseNet;
    $CC393E48:
      begin
        if not FMemory.IsValid(A, 12) then
        begin
          Value := $800200D3;
          Exit
        end;
        FMemory.Write32(A, FNetPoolSize);
        FMemory.Write32(A + 4, 0);
        FMemory.Write32(A + 8, FNetPoolSize);
      end;
    $0BF0A3AE:
      Value := $80410180; // No adhoc group has assigned an interface address.
      $89360950:
      begin
        if not FMemory.IsValid(A, 6) or not FMemory.IsValid(B, 18) then
        begin
          Value := $800200D3;
          Exit
        end;
        var Text := '';
        for var I := 0 to 5 do
        begin
          if I <> 0 then
            Text := Text + ':';
          Text := Text + LowerCase(IntToHex(FMemory.Read8(A + Cardinal(I)), 2))
        end;
        FMemory.Load(B, TEncoding.ASCII.GetBytes(Text + #0));
      end;
    $D27961C9:
      begin
        if not FMemory.IsValid(A, 18) or not FMemory.IsValid(B, 6) then
        begin
          Value := $800200D3;
          Exit
        end;
        var Text := FMemory.ReadString(A, 18);
        if Length(Text) <> 17 then
        begin
          Value := $80000107;
          Exit
        end;
        var Bytes: TBytes;
        SetLength(Bytes, 6);
        for var I := 0 to 5 do
        begin
          var H := Hex(Text[I * 3 + 1]);
          var L := Hex(Text[I * 3 + 2]);
          if (H < 0) or (L < 0) or ((I < 5) and (Text[I * 3 + 3] <> ':')) then
          begin
            Value := $80000107;
            Exit
          end;
          Bytes[I] := H * 16 + L;
        end;
        FMemory.Load(B, Bytes);
      end;
  else
    Result := False
  end;
end;

procedure TPSPSystemHLE.WriteTick(Address: Cardinal; Tick: UInt64);
begin
  FMemory.Write32(Address, Cardinal(Tick and $FFFFFFFF));
  FMemory.Write32(Address + 4, Cardinal(Tick shr 32));
end;

procedure TPSPSystemHLE.WriteClock(Address: Cardinal; Clock: TDateTime);
begin
  var Y, M, D, H, N, S, MS: Word;
  DecodeDateTime(Clock, Y, M, D, H, N, S, MS);
  FMemory.Write16(Address, Y);
  FMemory.Write16(Address + 2, M);
  FMemory.Write16(Address + 4, D);
  FMemory.Write16(Address + 6, H);
  FMemory.Write16(Address + 8, N);
  FMemory.Write16(Address + 10, S);
  FMemory.Write32(Address + 12, Cardinal(MS) * 1000);
end;

function TPSPSystemHLE.RTC(NID, A, B, C: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  case NID of
    $36075567:
      begin
        if not FMemory.IsValid(A, 16) or not FMemory.IsValid(B, 4) then
        begin
          Value := $FFFFFFFF;
          Exit
        end;
        var Year := FMemory.Read16(A);
        if Year < 1980 then
        begin
          FMemory.Write32(B, 0);
          Value := $FFFFFFFF;
          Exit
        end;
        if Year >= 2108 then
        begin
          FMemory.Write32(B, $FF9FBF7D);
          Value := $FFFFFFFF;
          Exit
        end;
        var DateBits := ((Cardinal(Year) - 1980) shl 9) or ((FMemory.Read16(A + 2) and 15) shl 5) or (FMemory.Read16(A + 4) and 31);
        var TimeBits := ((FMemory.Read16(A + 6) and 31) shl 11) or ((FMemory.Read16(A + 8) and 63) shl 5) or ((FMemory.Read16(A + 10) shr 1) and 31);
        FMemory.Write32(B, (DateBits shl 16) or TimeBits);
      end;
    $F006F264:
      begin
        if not FMemory.IsValid(A, 16) then
        begin
          Value := $FFFFFFFF;
          Exit
        end;
        FMemory.Write16(A, 1980 + ((B shr 25) and 127));
        FMemory.Write16(A + 2, (B shr 21) and 15);
        FMemory.Write16(A + 4, (B shr 16) and 31);
        FMemory.Write16(A + 6, (B shr 11) and 31);
        FMemory.Write16(A + 8, (B shr 5) and 63);
        FMemory.Write16(A + 10, (B and 31) * 2);
        FMemory.Write32(A + 12, 0);
      end;
    $27C4594C:
      begin
        if not FMemory.IsValid(A, 16) or not FMemory.IsValid(B, 4) then
        begin
          Value := 1;
          Exit
        end;
        var Date: TDateTime;
        if not TryEncodeDateTime(FMemory.Read16(A), FMemory.Read16(A + 2), FMemory.Read16(A + 4),
          FMemory.Read16(A + 6), FMemory.Read16(A + 8), FMemory.Read16(A + 10), 0, Date) then
        begin
          Value := $80000107;
          Exit
        end;
        if FMemory.Read32(A + 12) >= 1000000 then
        begin
          Value := $80000107;
          Exit
        end;
        var Seconds := DateTimeToUnix(Date, True);
        FMemory.Write32(B, Cardinal(UInt64(Seconds) and $FFFFFFFF));
      end;
    $42842C77, $DBF74F1B:
      begin
        if not FMemory.IsValid(A, 8) or not FMemory.IsValid(B, 8) then
        begin
          Value := $FFFFFFFF;
          Exit
        end;
        var Tick := UInt64(FMemory.Read32(B)) or (UInt64(FMemory.Read32(B + 4)) shl 32);
        var Day := Tick div UInt64(86400000000);
        var WithinDay := Tick mod UInt64(86400000000);
        if Day > 3652058 then
          Exit;
        var Date: TDateTime := EncodeDate(1, 1, 1) + Int64(Day);
        var Year, Month, DayOfMonth: Word;
        DecodeDate(Date, Year, Month, DayOfMonth);
        var TargetYear: Int64 := Year;
        var TargetMonth: Int64 := Month;
        if NID = $42842C77 then
          TargetYear := TargetYear + Integer(C)
        else
        begin
          TargetYear := TargetYear + Integer(C) div 12;
          TargetMonth := TargetMonth + Integer(C) mod 12;
          if TargetMonth < 1 then
          begin
            Inc(TargetMonth, 12);
            Dec(TargetYear)
          end;
          if TargetMonth > 12 then
          begin
            Dec(TargetMonth, 12);
            Inc(TargetYear)
          end;
        end;
        if (TargetYear < 1) or (TargetYear > 9999) then
          Exit;
        if (TargetMonth = 2) and (DayOfMonth = 29) and not IsLeapYear(TargetYear) then
          DayOfMonth := 28;
        if TryEncodeDate(TargetYear, TargetMonth, DayOfMonth, Date) then
          WriteTick(A, UInt64(Trunc(Date - EncodeDate(1, 1, 1))) * UInt64(86400000000) + WithinDay);
      end;
    $9ED0AE87:
      begin
        var Left := UInt64(FMemory.Read32(A)) or (UInt64(FMemory.Read32(A + 4)) shl 32);
        var Right := UInt64(FMemory.Read32(B)) or (UInt64(FMemory.Read32(B + 4)) shl 32);
        if Left < Right then
          Value := $FFFFFFFF
        else if Left > Right then
          Value := 1;
      end;
    $C41C2853:
      Value := 1000000;
    $3F7AD767:
      WriteTick(A, FTickBase + FKernel.Time);
    $011F03C1, $029CA3B3:
      begin
        var Tick := FTickBase + FKernel.Time;
        Value := Cardinal(Tick and $FFFFFFFF);
        FCPU.Registers[3] := Cardinal(Tick shr 32);
      end;
    $4CFA57B0:
      WriteClock(A, FClockBase + FKernel.Time / 86400000000.0 + Integer(B) / 1440.0);
    $E7C27D1B:
      WriteClock(A, TTimeZone.local.ToLocalTime(FClockBase + FKernel.Time / 86400000000.0));
    $42307A17:
      Value := Ord((A mod 4 = 0) and ((A mod 100 <> 0) or (A mod 400 = 0)));
    $05EF322C:
      if (A < 1) or (A > 9999) or (B < 1) or (B > 12) then
        Value := $80000107
      else
        Value := DaysInAMonth(A, B);
    $57726BC1:
      begin
        var Date: TDateTime;
        if TryEncodeDate(A, B, C, Date) then
          Value := DayOfWeek(Date) - 1
        else
          Value := $80000107;
      end;
  else
    Result := False;
  end;
end;

function TPSPSystemHLE.Handle(const ModuleName: string; NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  if ModuleName = 'sceHprm' then
  begin
    case NID of
      $208DB1BD, $7E69EDA4, $219C58F1:
        Value := 0; // No remote, headphone or microphone accessory.
        $1910B327:
        if not FMemory.IsValid(A, 4) then
          Value := $800200D3
        else
          FMemory.Write32(A, 0);
      $2BCEC83E, $40D2F9F0:
        if not FMemory.IsValid(A, 16) then
          Value := $800200D3
        else
          FMemory.Zero(A, 16);
    else
      Result := False
    end;
    Exit;
  end;
  if ModuleName = 'sceNet' then
    Exit(Net(NID, A, B, C, FCPU.Registers[7], Value));
  if (ModuleName='sceNetAdhoc') or (ModuleName='sceNetAdhocMatching') or (ModuleName='sceNetAdhocctl') then
    Exit(Adhoc(ModuleName,NID,A,B,C,Value));
  if ModuleName = 'sceWlanDrv' then
  begin
    case NID of
      $D7763699, $93440B11:
        Value := 0; // Emulated wireless switch is off.
        $0C622081:
        if not FMemory.IsValid(A, 6) then
          Value := $800200D3
        else
          FMemory.Load(A, TBytes.Create($02, $52, $4D, $50, $53, $01));
    else
      Result := False
    end;
    Exit;
  end;
  if (ModuleName = 'sceOpenPSID') and (NID = $C69BEBCE) then
  begin
    if not FMemory.IsValid(A, 16) then
    begin
      Value := $80000103;
      Exit
    end;
    // Stable identity of the emulated console, independent of host identifiers.
    FMemory.Load(A, TBytes.Create($52, $65, $74, $72, $6F, $4D, $75, $6C, $50, $53, $50, $00, $01, $00, $00, $01));
    Exit;
  end;
  if ModuleName = 'scePspNpDrm_user' then
  begin
    case NID of
      $A1336091:
        begin
          if not FMemory.IsValid(A, 16) then
          begin
            Value := $80000103;
            Exit;
          end;
          for var I := 0 to 15 do
            FLicenseKey[I] := FMemory.Read8(A + Cardinal(I));
          FHasLicenseKey := True;
        end;
      $9B745542:
        begin
          FillChar(FLicenseKey, SizeOf(FLicenseKey), 0);
          FHasLicenseKey := False;
        end;
    else
      Result := False;
    end;
    Exit;
  end;
  if ModuleName = 'sceRtc' then
    Exit(RTC(NID, A, B, C, Value));
  if ModuleName = 'UtilsForUser' then
    case NID of
      $37FB5C42:
        Value := 0; // General purpose input pins.
        $920F104A, $79D1C3FA, $B435DEC5:
        Value := 0; // Interpreter fetches coherent guest memory.
        $3EE30821, $34B9FA9E, $C2DF770E, $BFA98062:
        if (Integer(B) < 0) or ((B <> 0) and not FMemory.IsValid(A, B)) then
          Value := $800200D3;
      $27CC57F0:
        begin
          Value := UInt64(DateTimeToUnix(FClockBase, True)) + FKernel.Time div 1000000;
          if A <> 0 then
            FMemory.Write32(A, Value);
        end;
      $71EC4271:
        begin
          if A <> 0 then
          begin
            FMemory.Write32(A, UInt64(DateTimeToUnix(FClockBase, True)) + FKernel.Time div 1000000);
            FMemory.Write32(A + 4, FKernel.Time mod 1000000);
          end;
          if B <> 0 then
            FMemory.Zero(B, 8);
        end;
    else
      Result := False;
    end
  else if ModuleName = 'sceImpose' then
    case NID of
      $36AA6E91:
        begin
          FLanguage := A;
          FButtonMode := B;
        end;
      $24FD7BCF:
        begin
          FMemory.Write32(A, FLanguage);
          FMemory.Write32(B, FButtonMode);
        end;
      $8C943191:
        begin
          FMemory.Write32(A, 0);
          FMemory.Write32(B, 3);
        end;
      $72189C48:
        FUMDPopup := A;
      $E0887BC8:
        Value := FUMDPopup;
      $8F6E3518:
        Value := FBacklight;
      $967F6D4A:
        FBacklight := A;
    else
      Result := False;
    end
  else if ModuleName = 'sceSuspendForUser' then
    case NID of
      $EADB1BD7:
        if A <> 0 then
          Value := $80000107
        else
          Inc(FPowerLocks);
      $3AEE7261:
        if A <> 0 then
          Value := $80000107
        else if FPowerLocks > 0 then
          Dec(FPowerLocks);
      $090CCB3F:
        FPowerTick := FKernel.Time;
    else
      Result := False;
    end
  else if ModuleName = 'scePower' then
    case NID of
      $04B7766E:
        begin
          var Slot := Integer(A);
          if Slot = -1 then
            for var I := 0 to High(FPowerCallbacks) do
              if FPowerCallbacks[I] = 0 then
              begin
                Slot := I;
                Break;
              end;
          if (Slot < 0) or (Slot > High(FPowerCallbacks)) then
            Value := $80000102
          else if FPowerCallbacks[Slot] <> 0 then
            Value := $80000020
          else
          begin
            FPowerCallbacks[Slot] := B;
            Value := Slot;
          end;
        end;
      $DFA8BAF8, $DB9D28DD:
        if A > High(FPowerCallbacks) then
          Value := $80000102
        else
          FPowerCallbacks[A] := 0;
      $87440F5E, $0AFD0D8B:
        Value := 1;
      $1E490401, $D3075926, $78A1A796, $EFD3C963:
        Value := 0;
      $2085D15D:
        Value := 100;
      $FEE03A2F, $FDB5BFE9:
        Value := FCPUClock;
      $478FE6F5, $BD681969:
        Value := FBusClock;
      $34F9C463:
        Value := FPLLClock;
      $843FBF43:
        if (A < 1) or (A > 333) then
          Value := $80000107
        else
        begin
          FCPUClock := A;
          FKernel.CPUClock := A;
        end;
      $B8D7B3FB:
        if (A < 1) or (A > 166) then
          Value := $80000107
        else
          FBusClock := A;
      $737486F2, $EBD177D6, $469989AD:
        if (A < 19) or (A > 333) or (B < 1) or (B > A) or (C < 1) or (C > 166) then
          Value := $80000107
        else
        begin
          FPLLClock := A;
          FCPUClock := B;
          FKernel.CPUClock := B;
          FBusClock := C;
        end;
    else
      Result := False;
    end
  else if ModuleName = 'sceUmdUser' then
    case NID of
      $87533940:
        FUMDReplacePermit := False;
      $CBE9F02A:
        FUMDReplacePermit := True;
      $C6183D47:
        if A <> 1 then
          Value := $80000107
        else if not FUMDPresent then
          Value := $80010013
        else
          FUMDActive := True;
      $E83742BA:
        FUMDActive := False;
      $46EBB729:
        Value := Ord(FUMDPresent);
      $6B4A146C:
        if not FUMDPresent then
          Value := 1
        else if FUMDActive then
          Value := $32
        else
          Value := $12;
      $8EF08FCE, $56202973, $4A9E5E29:
        if not FUMDPresent then
          Value := $800201A8;
      $20628E6F, $6AF9B50A:
        Value := 0;
      $340B7686:
        begin
          FMemory.Write32(A, 8);
          FMemory.Write32(A + 4, $10);
        end;
      $AEE7404D:
        FUMDCallback := A;
      $BD2BDE07:
        if FUMDCallback = A then
          FUMDCallback := 0
        else
          Value := $80000107;
    else
      Result := False;
    end
  else if ModuleName = 'sceUtility' then
    case NID of
      $45C18506:
        case A of
          2:
            if (B = 0) or (B = 1) or (B = 6) or (B = 11) then
              FAdhocChannel := B
            else
              Value := $80110104;
          3:
            FWlanPowerSave := B;
        else
          Value := $80110103
        end;
      $E49BFE92, $F7D8D092, $64D50C56:
        begin
          var Id := A;
          if NID = $F7D8D092 then
            Id := Id or $300
          else if NID = $64D50C56 then
            Id := Id or $100;
          if not FModules.ContainsKey(Id) then
          begin
            if NID = $F7D8D092 then
              Value := $80110F03
            else
              Value := $80111103
          end
          else
            FModules.Remove(Id);
        end;
      $2A2B3DE0, $C629AF26, $1579A159:
        begin
          var Id := A;
          if NID = $C629AF26 then
            Id := Id or $300;
          if NID = $1579A159 then
          begin
            if (A < 1) or (A > 7) then
            begin
              Value := $80111101;
              Exit;
            end;
            Id := Id or $100;
          end;
          if ((Id shr 8) < 1) or ((Id shr 8) > 6) then
            Value := $80111101
          else if FModules.ContainsKey(Id) then
            Value := $80111102
          else
            FModules.Add(Id, True);
        end;
      $A5DA2406:
        begin
          var Param: Cardinal;
          case A of
            2:
              Param := FAdhocChannel;
            3:
              Param := FWlanPowerSave;
            6, 7:
              Param := 0;
            5:
              Param := 1;
            4:
              Param := 2;
            8:
              Param := FLanguage;
            9:
              Param := FButtonMode;
            10:
              Param := 9;
          else
            Value := $80110103;
            Exit;
          end;
          FMemory.Write32(B, Param);
        end;
      $34B78343:
        begin
          if A <> 1 then
            Value := $80110103
          else if C < 9 then
            Value := $80110104
          else
            FMemory.Load(B, TEncoding.UTF8.GetBytes('RetroMul' + #0));
        end;
    else
      Result := False;
    end
  else if (ModuleName = 'UtilsForUser') and (NID = $37FB5C42) then
    Value := 0
  else
    Result := False;
end;

end.

