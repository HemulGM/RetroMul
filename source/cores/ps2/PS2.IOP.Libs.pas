unit PS2.IOP.Libs;

// The system libraries IOP modules import, implemented in Delphi: sysmem,
// loadcore, intrman, thbase/thevent/thsemap/thmsgbx/thfpool/thvpool,
// sysclib, stdio, sifman, sifcmd, timrman, vblank, dmacman, cdvdman,
// ioman/iomanx, modload, heaplib and secrman. Function numbers are the export
// indices of the ps2sdk export tables; structures, error codes and behaviour
// follow the ps2sdk headers and its reimplementations of these modules
// (threadman, intrman, sysmem, timrman, vblank...; AFL 2.0). Unknown
// functions return 0 and are logged once.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, PS2.Types, PS2.IOP.Kernel;

// HLE library number for an import table name, or -1.
function IOPLibraryIndex(const Name: string): Integer;
procedure IOPLibraryCall(K: TPS2IOPKernel; Lib, Fn: Integer);
// printf-style formatting of guest arguments.
function IOPFormat(K: TPS2IOPKernel; FormatAddress: Cardinal; NextArg: TFunc<Cardinal>): string;

implementation

uses
  PS2.IOP.CPU, PS2.IOP.FileIO, PS2.IOP.Hardware, PS2.IOP.Loader, PS2.SIF, Core.DVD.Image;

const
  // usbd: the USB stack is absent (no devices): drivers register and wait.
  LibNames: array[0..25] of string = ('sysmem', 'loadcore', 'intrman', 'thbase', 'thevent', 'thsemap', 'thmsgbx',
    'thfpool', 'thvpool', 'sysclib', 'stdio', 'sifman', 'sifcmd', 'timrman', 'vblank', 'dmacman', 'cdvdman',
    'ioman', 'iomanx', 'modload', 'heaplib', 'thrdman', 'excepman', 'ssbusc', 'secrman', 'usbd');
  LSysmem = 0;
  LLoadcore = 1;
  LIntrman = 2;
  LThbase = 3;
  LThevent = 4;
  LThsema = 5;
  LThmsgbx = 6;
  LThfpool = 7;
  LThvpool = 8;
  LSysclib = 9;
  LStdio = 10;
  LSifman = 11;
  LSifcmd = 12;
  LTimrman = 13;
  LVblank = 14;
  LDmacman = 15;
  LCdvdman = 16;
  LIoman = 17;
  LIomanx = 18;
  LModload = 19;
  LHeaplib = 20;
  LSecrman = 24;

  KEOk = 0;
  KEUnknownThid = -407;
  KEUnknownSemid = -408;
  KEUnknownEvfid = -409;
  KEReleaseWait = -418;
  KESemaZero = -419;
  KESemaOvf = -420;
  KEEvfCond = -421;
  KEEvfMulti = -422;
  KEEvfIlpat = -423;
  KEMboxNoMsg = -424;
  // Event flag attribute: more than one thread may wait.
  EventMulti = $2;
  KEUnknownModule = -202;

function IOPLibraryIndex(const Name: string): Integer;
begin
  for var K := 0 to High(LibNames) do
    if LibNames[K] = Name then
      Exit(K);
  Result := -1;
end;

function IOPFormat(K: TPS2IOPKernel; FormatAddress: Cardinal; NextArg: TFunc<Cardinal>): string;
begin
  var Fmt := K.ReadString(FormatAddress, 4096);
  var SB := TStringBuilder.Create;
  try
    var I := 1;
    while I <= Length(Fmt) do
    begin
      var C := Fmt[I];
      if (C <> '%') or (I = Length(Fmt)) then
      begin
        SB.Append(C);
        Inc(I);
        Continue;
      end;
      Inc(I);
      var Left := False;
      var Zero := False;
      var Plus := False;
      while (I <= Length(Fmt)) and CharInSet(Fmt[I], ['-', '0', '+', ' ', '#']) do
      begin
        case Fmt[I] of
          '-': Left := True;
          '0': Zero := True;
          '+': Plus := True;
        end;
        Inc(I);
      end;
      var Width := 0;
      if (I <= Length(Fmt)) and (Fmt[I] = '*') then
      begin
        Width := Integer(NextArg());
        Inc(I);
      end;
      while (I <= Length(Fmt)) and CharInSet(Fmt[I], ['0'..'9']) do
      begin
        Width := Width * 10 + Ord(Fmt[I]) - Ord('0');
        Inc(I);
      end;
      var Prec := -1;
      if (I <= Length(Fmt)) and (Fmt[I] = '.') then
      begin
        Inc(I);
        Prec := 0;
        if (I <= Length(Fmt)) and (Fmt[I] = '*') then
        begin
          Prec := Integer(NextArg());
          Inc(I);
        end;
        while (I <= Length(Fmt)) and CharInSet(Fmt[I], ['0'..'9']) do
        begin
          Prec := Prec * 10 + Ord(Fmt[I]) - Ord('0');
          Inc(I);
        end;
      end;
      while (I <= Length(Fmt)) and CharInSet(Fmt[I], ['l', 'h', 'q', 'L', 'z']) do
        Inc(I);
      if I > Length(Fmt) then
        Break;
      var Spec := Fmt[I];
      Inc(I);
      var S: string;
      case Spec of
        'd', 'i':
          begin
            var V := Integer(NextArg());
            S := IntToStr(Abs(Int64(V)));
            if Prec > Length(S) then
              S := StringOfChar('0', Prec - Length(S)) + S;
            if V < 0 then
              S := '-' + S
            else if Plus then
              S := '+' + S;
          end;
        'u': S := UIntToStr(NextArg());
        'x': S := LowerCase(IntToHex(NextArg(), 1));
        'X', 'p': S := IntToHex(NextArg(), 1);
        'o':
          begin
            var V := NextArg();
            S := '';
            repeat
              S := Chr(Ord('0') + Integer(V and 7)) + S;
              V := V shr 3;
            until V = 0;
          end;
        'c': S := Chr(Byte(NextArg()));
        's':
          begin
            var P := NextArg();
            if P = 0 then
              S := '(null)'
            else
              S := K.ReadString(P, 4096);
            if (Prec >= 0) and (Length(S) > Prec) then
              S := Copy(S, 1, Prec);
          end;
        '%': S := '%';
      else
        S := '%' + Spec;
      end;
      if CharInSet(Spec, ['x', 'X', 'u', 'o']) and (Prec > Length(S)) then
        S := StringOfChar('0', Prec - Length(S)) + S;
      if Length(S) < Width then
      begin
        if Left then
          S := S + StringOfChar(' ', Width - Length(S))
        else if Zero and not CharInSet(Spec, ['s', 'c']) then
        begin
          if (S <> '') and (S[1] = '-') then
            S := '-' + StringOfChar('0', Width - Length(S)) + Copy(S, 2, MaxInt)
          else
            S := StringOfChar('0', Width - Length(S)) + S;
        end
        else
          S := StringOfChar(' ', Width - Length(S)) + S;
      end;
      SB.Append(S);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function ArgsFrom(K: TPS2IOPKernel; First: Integer): TFunc<Cardinal>;
begin
  var N := First;
  Result :=
    function: Cardinal
    begin
      Result := K.Arg(N);
      Inc(N);
    end;
end;

function ArgsAt(K: TPS2IOPKernel; Address: Cardinal): TFunc<Cardinal>;
begin
  var A := Address;
  Result :=
    function: Cardinal
    begin
      Result := K.R32(A);
      Inc(A, 4);
    end;
end;

procedure WriteGuestString(K: TPS2IOPKernel; Dest: Cardinal; const S: string);
begin
  var B := TEncoding.ANSI.GetBytes(S);
  for var I := 0 to Length(B) - 1 do
    K.W8(Dest + Cardinal(I), B[I]);
  K.W8(Dest + Cardinal(Length(B)), 0);
end;

function GuestStrLen(K: TPS2IOPKernel; A: Cardinal): Cardinal;
begin
  Result := 0;
  while (Result < $200000) and (K.R8(A + Result) <> 0) do
    Inc(Result);
end;

function FreeSlot(K: TPS2IOPKernel; Kind: Integer): Integer;
begin
  for var I := 1 to IOPMaxObjects do
    case Kind of
      0: if not K.Semas[I].Used then Exit(I);
      1: if not K.Events[I].Used then Exit(I);
      2: if not K.Mbxs[I].Used then Exit(I);
      3: if not K.Pools[I].Used then Exit(I);
    end;
  Result := -1;
end;

function ValidThread(K: TPS2IOPKernel; Id: Integer): Boolean;
begin
  Result := (Id >= 1) and (Id <= IOPMaxThreads) and K.Threads[Id].Used;
end;

function ValidId(Id: Integer): Boolean;
begin
  Result := (Id >= 1) and (Id <= IOPMaxObjects);
end;

procedure WriteClock(K: TPS2IOPKernel; Address: Cardinal; Ticks: Int64);
begin
  K.W32(Address, Cardinal(Ticks and $FFFFFFFF));
  K.W32(Address + 4, Cardinal((Ticks shr 32) and $FFFFFFFF));
end;

function ReadClock(K: TPS2IOPKernel; Address: Cardinal): Int64;
begin
  Result := Int64(K.R32(Address)) or (Int64(K.R32(Address + 4)) shl 32);
end;

function SysmemCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    4:
      begin
        Result := K.Allocator.AllocateMode(K.Arg(0), K.Arg(1), K.Arg(2));
        if K.Log <> nil then
          K.Warn(Format('AllocSysMemory(%d, %x, %x) -> %x (largest free %x)', [K.Arg(0), K.Arg(1), K.Arg(2), Result,
            K.Allocator.LargestFree]));
      end;
    5:
      K.Allocator.Release(K.Arg(0));
    6: Result := PS2IOPRAMSize;
    7: Result := K.Allocator.LargestFree;
    8: Result := K.Allocator.FreeTotal;
    9: Result := K.Arg(0);
    10: Result := K.Allocator.BlockSize(K.Arg(0));
    14: K.Print(IOPFormat(K, K.Arg(0), ArgsFrom(K, 1)));
  end;
end;

function LoadcoreCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    6, 10: Result := Cardinal(K.RegisterLibrary(K.Arg(0)));
  end;
end;

function IntrmanCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  var Line := Integer(K.Arg(0));
  if (K.Log <> nil) and (Fn in [4..7]) then
    K.Warn(Format('intrman:%d line %d handler %.6x', [Fn, Line, K.Arg(2)]));
  case Fn of
    4:
      if (Line >= 0) and (Line <= High(K.Intr)) then
      begin
        K.Intr[Line].Registered := True;
        K.Intr[Line].Mode := K.Arg(1);
        K.Intr[Line].Handler := K.Arg(2);
        K.Intr[Line].Arg := K.Arg(3);
        // DMA lines are masked by the channel's own enable bit.
        if Line >= 32 then
          K.Intr[Line].Enabled := True;
      end;
    5:
      if (Line >= 0) and (Line <= High(K.Intr)) then
        K.Intr[Line].Registered := False;
    6:
      if (Line >= 0) and (Line <= High(K.Intr)) then
        K.Intr[Line].Enabled := True;
    7:
      if (Line >= 0) and (Line <= High(K.Intr)) then
      begin
        if K.Arg(1) <> 0 then
          K.W32(K.Arg(1), Cardinal(Line));
        K.Intr[Line].Enabled := False;
      end;
    8, 17, 19:
      begin
        var T := K.CurrentThread;
        if (Fn <> 8) and (K.Arg(0) <> 0) then
          if (T > 0) and K.Threads[T].IntrOff then
            K.W32(K.Arg(0), 0)
          else
            K.W32(K.Arg(0), 1);
        if T > 0 then
          K.Threads[T].IntrOff := True;
      end;
    9:
      if K.CurrentThread > 0 then
        K.Threads[K.CurrentThread].IntrOff := False;
    18, 20:
      if K.CurrentThread > 0 then
        K.Threads[K.CurrentThread].IntrOff := K.Arg(0) = 0;
    23: Result := Ord(K.InCall);
    24: Result := IOPIntrStackTop;
  end;
end;

function ThbaseCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  var Id := Integer(K.Arg(0));
  if (Id = 0) and (Fn in [14, 15, 22, 23, 42]) then
    Id := K.CurrentThread;
  case Fn of
    4:
      begin
        var P := K.Arg(0);
        Result := Cardinal(K.CreateThread(K.R32(P), K.R32(P + 8), K.R32(P + 16), K.R32(P + 12), K.R32(P + 4),
          K.CPU.R[IOPRegGP]));
        if K.Log <> nil then
          K.Warn(Format('CreateThread entry %.6x prio %d stack %x -> %d', [K.R32(P + 8), K.R32(P + 16), K.R32(P + 12),
            Integer(Result)]));
      end;
    5:
      if ValidThread(K, Id) and (Id <> K.CurrentThread) then
        K.DeleteThread(Id)
      else
        Result := Cardinal(KEUnknownThid);
    6, 7:
      if ValidThread(K, Id) then
      begin
        K.StartThread(Id, K.Arg(1), K.Arg(2));
        if Fn = 7 then
          K.Threads[Id].Ctx.R[IOPRegA0] := K.Arg(1);
      end
      else
        Result := Cardinal(KEUnknownThid);
    8, 9:
      begin
        var T := K.CurrentThread;
        if (K.Log <> nil) and (T > 0) then
          K.Warn(Format('ExitThread %d (entry %.6x)', [T, K.Threads[T].Entry]));
        if T > 0 then
        begin
          K.Threads[T].State := ThDormant;
          if Fn = 9 then
            K.DeleteThread(T);
          K.Current := -1;
        end;
      end;
    10, 11:
      if ValidThread(K, Id) and (Id <> K.CurrentThread) then
        K.Threads[Id].State := ThDormant
      else
        Result := Cardinal(KEUnknownThid);
    14, 15:
      if ValidThread(K, Id) then
      begin
        var Prio := Integer(K.Arg(1));
        if Prio = 0 then
          Prio := K.Threads[Id].InitPriority;
        K.Threads[Id].Priority := Prio;
      end
      else
        Result := Cardinal(KEUnknownThid);
    16, 17:
      begin
        var T := K.CurrentThread;
        if (T > 0) and ((K.Arg(0) = 0) or (Integer(K.Arg(0)) = K.Threads[T].Priority)) then
          K.MakeReady(T);
      end;
    18, 19:
      if ValidThread(K, Id) and (K.Threads[Id].State = ThWaiting) then
        K.Wake(Id, Cardinal(KEReleaseWait));
    20: Result := Cardinal(K.CurrentThread);
    22, 23:
      if ValidThread(K, Id) then
      begin
        var I := K.Arg(1);
        var T: PIOPThread := @K.Threads[Id];
        var Status: Cardinal;
        if T.State = ThDormant then
          Status := 16
        else if T.State = ThWaiting then
          Status := 4
        else if Id = K.CurrentThread then
          Status := 1
        else
          Status := 2;
        if I <> 0 then
        begin
          K.W32(I, T.Attr);
          K.W32(I + 4, T.Option);
          K.W32(I + 8, Status);
          K.W32(I + 12, T.Entry);
          K.W32(I + 16, T.StackBase);
          K.W32(I + 20, T.StackSize);
          K.W32(I + 24, T.GP);
          K.W32(I + 28, Cardinal(T.InitPriority));
          K.W32(I + 32, Cardinal(T.Priority));
          K.W32(I + 36, T.Wait);
          K.W32(I + 40, Cardinal(T.WaitId));
          K.W32(I + 44, Cardinal(T.WakeupCount));
        end;
      end
      else
        Result := Cardinal(KEUnknownThid);
    24:
      begin
        var T := K.CurrentThread;
        if T > 0 then
          if K.Threads[T].WakeupCount > 0 then
            Dec(K.Threads[T].WakeupCount)
          else
            K.Block(WaitSleep);
      end;
    25, 26:
      if ValidThread(K, Id) then
      begin
        if (K.Threads[Id].State = ThWaiting) and (K.Threads[Id].Wait = WaitSleep) then
          K.Wake(Id, 0)
        else
          Inc(K.Threads[Id].WakeupCount);
      end
      else
        Result := Cardinal(KEUnknownThid);
    27, 28:
      begin
        if Id = 0 then
          Id := K.CurrentThread;
        if ValidThread(K, Id) then
        begin
          Result := Cardinal(K.Threads[Id].WakeupCount);
          K.Threads[Id].WakeupCount := 0;
        end;
      end;
    33:
      begin
        var T := K.CurrentThread;
        if T > 0 then
        begin
          K.Threads[T].WakeAt := K.CPU.Cycles * 8 + Max(Int64(K.Arg(0)), 1) * 294912 div 1000;
          K.Block(WaitDelay);
          K.ScheduleTimers;
        end;
      end;
    34: WriteClock(K, K.Arg(0), K.CPU.Cycles);
    35, 36:
      begin
        var Ticks := ReadClock(K, K.Arg(0));
        for var A := 0 to High(K.Alarms) do
          if not K.Alarms[A].Used then
          begin
            K.Alarms[A].Used := True;
            K.Alarms[A].At := K.CPU.Cycles * 8 + Max(Ticks, 1) * 8;
            K.Alarms[A].Handler := K.Arg(1);
            K.Alarms[A].Arg := K.Arg(2);
            K.ScheduleTimers;
            Break;
          end;
      end;
    37, 38:
      begin
        Result := Cardinal(-1);
        for var A := 0 to High(K.Alarms) do
          if K.Alarms[A].Used and (K.Alarms[A].Handler = K.Arg(0)) and (K.Alarms[A].Arg = K.Arg(1)) then
          begin
            K.Alarms[A].Used := False;
            Result := 0;
          end;
        K.ScheduleTimers;
      end;
    39: WriteClock(K, K.Arg(1), Int64(K.Arg(0)) * 36864 div 1000);
    40:
      begin
        var USec := ReadClock(K, K.Arg(0)) * 1000 div 36864;
        if K.Arg(1) <> 0 then
          K.W32(K.Arg(1), Cardinal(USec div 1000000));
        if K.Arg(2) <> 0 then
          K.W32(K.Arg(2), Cardinal(USec mod 1000000));
      end;
    42:
      if ValidThread(K, Id) then
        Result := Cardinal(K.Threads[Id].Priority);
    43: Result := Cardinal(K.CPU.Cycles and $FFFFFFFF);
  end;
end;

function TheventCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  var Id := Integer(K.Arg(0));
  if (Fn > 4) and (Fn <> 12) and not (ValidId(Id) and K.Events[Id].Used) then
    Exit(Cardinal(KEUnknownEvfid));
  case Fn of
    4:
      begin
        var S := FreeSlot(K, 1);
        if S < 0 then
          Exit(Cardinal(-1));
        var P := K.Arg(0);
        K.Events[S].Used := True;
        K.Events[S].Attr := K.R32(P);
        K.Events[S].Option := K.R32(P + 4);
        K.Events[S].Bits := K.R32(P + 8);
        K.Events[S].Init := K.Events[S].Bits;
        Result := Cardinal(S);
      end;
    5: K.Events[Id].Used := False;
    6, 7:
      begin
        K.Events[Id].Bits := K.Events[Id].Bits or K.Arg(1);
        K.CheckEventWaiters(Id);
      end;
    8, 9: K.Events[Id].Bits := K.Events[Id].Bits and K.Arg(1);
    10, 11:
      begin
        var Want := K.Arg(1);
        var Mode := K.Arg(2);
        if Want = 0 then
          Exit(Cardinal(KEEvfIlpat));
        // A second waiter needs the multiple-wait attribute.
        if (Fn = 10) and ((K.Events[Id].Attr and EventMulti) = 0) then
          for var T := 1 to IOPMaxThreads do
            if K.Threads[T].Used and (K.Threads[T].State = ThWaiting) and (K.Threads[T].Wait = WaitEvent) and
              (K.Threads[T].WaitId = Id) then
              Exit(Cardinal(KEEvfMulti));
        if K.EventMatches(K.Events[Id].Bits, Want, Mode) then
        begin
          if K.Arg(3) <> 0 then
            K.W32(K.Arg(3), K.Events[Id].Bits);
          if (Mode and $10) <> 0 then
            K.Events[Id].Bits := 0;
        end
        else if Fn = 11 then
          Result := Cardinal(KEEvfCond)
        else
          K.Block(WaitEvent, Id, Want, Mode, K.Arg(3));
      end;
    13, 14:
      begin
        var I := K.Arg(1);
        K.W32(I, K.Events[Id].Attr);
        K.W32(I + 4, K.Events[Id].Option);
        K.W32(I + 8, K.Events[Id].Init);
        K.W32(I + 12, K.Events[Id].Bits);
        K.W32(I + 16, 0);
      end;
  end;
end;

function ThsemaCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  var Id := Integer(K.Arg(0));
  if (Fn > 4) and not (ValidId(Id) and K.Semas[Id].Used) then
    Exit(Cardinal(KEUnknownSemid));
  case Fn of
    4:
      begin
        var S := FreeSlot(K, 0);
        if S < 0 then
          Exit(Cardinal(-1));
        var P := K.Arg(0);
        K.Semas[S].Used := True;
        K.Semas[S].Attr := K.R32(P);
        K.Semas[S].Option := K.R32(P + 4);
        K.Semas[S].Init := Integer(K.R32(P + 8));
        K.Semas[S].Max := Integer(K.R32(P + 12));
        K.Semas[S].Count := K.Semas[S].Init;
        Result := Cardinal(S);
      end;
    5:
      begin
        K.Semas[Id].Used := False;
        for var T := 1 to IOPMaxThreads do
          if K.Threads[T].Used and (K.Threads[T].State = ThWaiting) and (K.Threads[T].Wait = WaitSema) and
            (K.Threads[T].WaitId = Id) then
            K.Wake(T, Cardinal(-425));
      end;
    6, 7:
      begin
        // A waiting thread takes the signal; else the count goes up to its
        // maximum.
        var Waiting := False;
        for var T := 1 to IOPMaxThreads do
          if K.Threads[T].Used and (K.Threads[T].State = ThWaiting) and (K.Threads[T].Wait = WaitSema) and
            (K.Threads[T].WaitId = Id) then
            Waiting := True;
        if not Waiting and (K.Semas[Id].Count >= K.Semas[Id].Max) then
          Exit(Cardinal(KESemaOvf));
        Inc(K.Semas[Id].Count);
        K.CheckSemaWaiters(Id);
      end;
    8:
      if K.Semas[Id].Count > 0 then
        Dec(K.Semas[Id].Count)
      else
        K.Block(WaitSema, Id);
    9:
      if K.Semas[Id].Count > 0 then
        Dec(K.Semas[Id].Count)
      else
        Result := Cardinal(KESemaZero);
    11, 12:
      begin
        var I := K.Arg(1);
        var Waiting := 0;
        for var T := 1 to IOPMaxThreads do
          if K.Threads[T].Used and (K.Threads[T].State = ThWaiting) and (K.Threads[T].Wait = WaitSema) and
            (K.Threads[T].WaitId = Id) then
            Inc(Waiting);
        K.W32(I, K.Semas[Id].Attr);
        K.W32(I + 4, K.Semas[Id].Option);
        K.W32(I + 8, Cardinal(K.Semas[Id].Init));
        K.W32(I + 12, Cardinal(K.Semas[Id].Max));
        K.W32(I + 16, Cardinal(K.Semas[Id].Count));
        K.W32(I + 20, Cardinal(Waiting));
      end;
  end;
end;

function ThmsgbxCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  var Id := Integer(K.Arg(0));
  if Fn in [8, 9] then
    Id := Integer(K.Arg(1));
  if (Fn > 4) and not (ValidId(Id) and K.Mbxs[Id].Used) then
    Exit(Cardinal(-410));
  case Fn of
    4:
      begin
        var S := FreeSlot(K, 2);
        if S < 0 then
          Exit(Cardinal(-1));
        K.Mbxs[S] := Default(TIOPMbx);
        K.Mbxs[S].Used := True;
        K.Mbxs[S].Attr := K.R32(K.Arg(0));
        K.Mbxs[S].Option := K.R32(K.Arg(0) + 4);
        Result := Cardinal(S);
      end;
    5: K.Mbxs[Id].Used := False;
    6, 7:
      begin
        var Msg := K.Arg(1);
        K.W32(Msg, 0);
        if K.Mbxs[Id].Count = 0 then
          K.Mbxs[Id].Head := Msg
        else
          K.W32(K.Mbxs[Id].Tail, Msg);
        K.Mbxs[Id].Tail := Msg;
        Inc(K.Mbxs[Id].Count);
        K.CheckMbxWaiters(Id);
      end;
    8, 9:
      if K.Mbxs[Id].Count > 0 then
      begin
        var Msg := K.Mbxs[Id].Head;
        K.Mbxs[Id].Head := K.R32(Msg);
        Dec(K.Mbxs[Id].Count);
        if K.Arg(0) <> 0 then
          K.W32(K.Arg(0), Msg);
      end
      else if Fn = 9 then
        Result := Cardinal(KEMboxNoMsg)
      else
        K.Block(WaitMbx, Id, K.Arg(0));
  end;
end;

function PoolCall(K: TPS2IOPKernel; Fn: Integer; Variable: Boolean): Cardinal;
begin
  Result := 0;
  case Fn of
    4:
      begin
        var S := FreeSlot(K, 3);
        if S < 0 then
          Exit(Cardinal(-1));
        var P := K.Arg(0);
        K.Pools[S] := Default(TIOPPool);
        K.Pools[S].Used := True;
        K.Pools[S].Attr := K.R32(P);
        K.Pools[S].Option := K.R32(P + 4);
        K.Pools[S].BlockSize := K.R32(P + 8);
        if not Variable then
          K.Pools[S].Blocks := K.R32(P + 12);
        Result := Cardinal(S);
      end;
    5:
      if ValidId(Integer(K.Arg(0))) then
        K.Pools[Integer(K.Arg(0))].Used := False;
    6, 7, 8:
      begin
        var Id := Integer(K.Arg(0));
        if not (ValidId(Id) and K.Pools[Id].Used) then
          Exit(0);
        if Variable then
          Result := K.Allocator.Allocate(K.Arg(1))
        else
          Result := K.Allocator.Allocate(K.Pools[Id].BlockSize);
      end;
    9: K.Allocator.Release(K.Arg(1));
  end;
end;

function SysclibCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  var A0 := K.Arg(0);
  var A1 := K.Arg(1);
  var A2 := K.Arg(2);
  case Fn of
    4:
      begin
        // setjmp: ra, sp, fp, s0..s7, gp.
        K.W32(A0, K.CPU.R[IOPRegRA]);
        K.W32(A0 + 4, K.CPU.R[IOPRegSP]);
        K.W32(A0 + 8, K.CPU.R[IOPRegFP]);
        for var R := 0 to 7 do
          K.W32(A0 + 12 + Cardinal(R) * 4, K.CPU.R[16 + R]);
        K.W32(A0 + 44, K.CPU.R[IOPRegGP]);
      end;
    5:
      begin
        K.CPU.R[IOPRegRA] := K.R32(A0);
        K.CPU.R[IOPRegSP] := K.R32(A0 + 4);
        K.CPU.R[IOPRegFP] := K.R32(A0 + 8);
        for var R := 0 to 7 do
          K.CPU.R[16 + R] := K.R32(A0 + 12 + Cardinal(R) * 4);
        K.CPU.R[IOPRegGP] := K.R32(A0 + 44);
        K.CPU.SetPC(K.CPU.R[IOPRegRA]);
        Result := A1;
        if Result = 0 then
          Result := 1;
      end;
    6: Result := Ord(UpCase(Chr(Byte(A0))));
    7: Result := Ord(LowerCase(Chr(Byte(A0)))[1]);
    10:
      begin
        for var I := 0 to Integer(A2) - 1 do
          if K.R8(A0 + Cardinal(I)) = Byte(A1) then
            Exit(A0 + Cardinal(I));
      end;
    11, 15:
      for var I := 0 to Integer(A2) - 1 do
      begin
        var D := Integer(K.R8(A0 + Cardinal(I))) - Integer(K.R8(A1 + Cardinal(I)));
        if D <> 0 then
          Exit(Cardinal(D));
      end;
    12, 13:
      begin
        if (A2 > 0) and (A2 < PS2IOPRAMSize) then
        begin
          var Tmp: TBytes;
          SetLength(Tmp, A2);
          for var I := 0 to Integer(A2) - 1 do
            Tmp[I] := K.R8(A1 + Cardinal(I));
          for var I := 0 to Integer(A2) - 1 do
            K.W8(A0 + Cardinal(I), Tmp[I]);
        end;
        Result := A0;
      end;
    14:
      begin
        for var I := 0 to Integer(A2) - 1 do
          K.W8(A0 + Cardinal(I), Byte(A1));
        Result := A0;
      end;
    16:
      if (A2 > 0) and (A2 < PS2IOPRAMSize) then
      begin
        var Tmp: TBytes;
        SetLength(Tmp, A2);
        for var I := 0 to Integer(A2) - 1 do
          Tmp[I] := K.R8(A0 + Cardinal(I));
        for var I := 0 to Integer(A2) - 1 do
          K.W8(A1 + Cardinal(I), Tmp[I]);
      end;
    17:
      for var I := 0 to Integer(A1) - 1 do
        K.W8(A0 + Cardinal(I), 0);
    19:
      begin
        var S := IOPFormat(K, A1, ArgsFrom(K, 2));
        WriteGuestString(K, A0, S);
        Result := Cardinal(Length(S));
      end;
    42:
      begin
        var S := IOPFormat(K, A1, ArgsAt(K, A2));
        WriteGuestString(K, A0, S);
        Result := Cardinal(Length(S));
      end;
    20:
      begin
        WriteGuestString(K, A0 + GuestStrLen(K, A0), K.ReadString(A1, 65536));
        Result := A0;
      end;
    28:
      begin
        WriteGuestString(K, A0 + GuestStrLen(K, A0), Copy(K.ReadString(A1, 65536), 1, Integer(A2)));
        Result := A0;
      end;
    21, 25, 32, 26:
      begin
        var S := K.ReadString(A0, 65536);
        var P: Integer;
        if Fn in [21, 25] then
          P := Pos(Chr(Byte(A1)), S)
        else
          P := LastDelimiter(Chr(Byte(A1)), S);
        if Byte(A1) = 0 then
          Exit(A0 + Cardinal(Length(S)));
        if P > 0 then
          Result := A0 + Cardinal(P - 1);
      end;
    22, 29:
      begin
        var I: Cardinal := 0;
        while True do
        begin
          if (Fn = 29) and (I >= A2) then
            Exit(0);
          var C1 := K.R8(A0 + I);
          var C2 := K.R8(A1 + I);
          if C1 <> C2 then
            Exit(Cardinal(Integer(C1) - Integer(C2)));
          if C1 = 0 then
            Exit(0);
          Inc(I);
        end;
      end;
    23:
      begin
        WriteGuestString(K, A0, K.ReadString(A1, 65536));
        Result := A0;
      end;
    30:
      begin
        var S := K.ReadString(A1, Integer(A2));
        for var I := 0 to Integer(A2) - 1 do
          if I < Length(S) then
            K.W8(A0 + Cardinal(I), Byte(S[I + 1]))
          else
            K.W8(A0 + Cardinal(I), 0);
        Result := A0;
      end;
    27: Result := GuestStrLen(K, A0);
    34:
      begin
        var P := Pos(K.ReadString(A1, 65536), K.ReadString(A0, 65536));
        if P > 0 then
          Result := A0 + Cardinal(P - 1);
      end;
    36, 38:
      begin
        var S := K.ReadString(A0, 64).Trim;
        var Base := Integer(A2);
        var V: Int64 := 0;
        var I := 1;
        var Neg := False;
        if (I <= Length(S)) and CharInSet(S[I], ['-', '+']) then
        begin
          Neg := S[I] = '-';
          Inc(I);
        end;
        if ((Base = 0) or (Base = 16)) and (Copy(S, I, 2).ToLower = '0x') then
        begin
          Base := 16;
          Inc(I, 2);
        end
        else if (Base = 0) and (Copy(S, I, 1) = '0') then
          Base := 8
        else if Base = 0 then
          Base := 10;
        while I <= Length(S) do
        begin
          var D: Integer;
          case S[I] of
            '0'..'9': D := Ord(S[I]) - Ord('0');
            'a'..'z': D := Ord(S[I]) - Ord('a') + 10;
            'A'..'Z': D := Ord(S[I]) - Ord('A') + 10;
          else
            D := 99;
          end;
          if D >= Base then
            Break;
          V := (V * Base + D) and $FFFFFFFF;
          Inc(I);
        end;
        if A1 <> 0 then
          K.W32(A1, A0 + Cardinal(I - 1));
        if Neg then
          V := -V;
        Result := Cardinal(V and $FFFFFFFF);
      end;
  end;
end;

function StdioCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    4:
      begin
        var S := IOPFormat(K, K.Arg(0), ArgsFrom(K, 1));
        K.Print(S);
        Result := Cardinal(Length(S));
      end;
    5: K.Print(Chr(Byte(K.Arg(0))));
    6: K.Print(K.ReadString(K.Arg(0), 4096) + #10);
  end;
end;

function SifmanCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    7, 32:
      begin
        // SifDmaTransfer_t: src (IOP), dest (EE), size, attr; 32 also
        // calls func(data) once the transfer is done.
        for var I := 0 to Integer(K.Arg(1)) - 1 do
        begin
          var D := K.Arg(0) + Cardinal(I) * 16;
          K.CopyToEE(K.R32(D), K.R32(D + 4), Integer(K.R32(D + 8)));
        end;
        if (Fn = 32) and (K.Arg(2) <> 0) then
          K.QueueCall(CallIntr, K.Arg(2), K.Arg(3), 0, 0, 0, 0);
        Result := K.DmaId;
        K.DmaId := Max(K.DmaId + 1, 1);
      end;
    9:
      begin
        K.CopyToEE(K.Arg(0), K.Arg(1), Integer(K.Arg(2)));
        Result := K.DmaId;
        K.DmaId := Max(K.DmaId + 1, 1);
      end;
    8: Result := Cardinal(-1);
    21: Result := K.SIF.MSFLG;
    23: Result := K.SIF.SMFLG;
    24: K.SIF.SMFLG := K.SIF.SMFLG or K.Arg(0);
    25: Result := K.SIF.EERecvAddr;
    26: Result := SIFIOPCmdBuffer;
    29: Result := 1;
  end;
end;

function SifcmdCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    6: Result := K.SifRegs[K.Arg(0) and 31];
    7:
      begin
        Result := K.SifRegs[K.Arg(0) and 31];
        K.SifRegs[K.Arg(0) and 31] := K.Arg(1);
      end;
    10:
      for var I := 0 to High(K.CmdHandlers) do
        if not K.CmdHandlers[I].Used or (K.CmdHandlers[I].Cid = K.Arg(0)) then
        begin
          K.CmdHandlers[I].Used := True;
          K.CmdHandlers[I].Cid := K.Arg(0);
          K.CmdHandlers[I].Handler := K.Arg(1);
          K.CmdHandlers[I].Data := K.Arg(2);
          Break;
        end;
    11:
      for var I := 0 to High(K.CmdHandlers) do
        if K.CmdHandlers[I].Used and (K.CmdHandlers[I].Cid = K.Arg(0)) then
          K.CmdHandlers[I].Used := False;
    12, 13, 28, 29:
      begin
        // (cid, packet, psize, src_extra, dest_extra, size_extra)
        var Size := Integer(K.Arg(5));
        if Size > 0 then
          K.CopyToEE(K.Arg(3), K.Arg(4), Size);
        var PSize := EnsureRange(Integer(K.Arg(2)), 16, 112);
        var P: TBytes;
        SetLength(P, PSize);
        for var I := 0 to PSize - 1 do
          P[I] := K.R8(K.Arg(1) + Cardinal(I));
        PCardinal(@P[0])^ := Cardinal(PSize) or (Cardinal(Size) shl 8);
        PCardinal(@P[4])^ := K.Arg(4);
        PCardinal(@P[8])^ := K.Arg(0);
        K.SIF.SendRawCommand(P);
        Result := 1;
      end;
    15:
      begin
        // Binding EE servers from the IOP is not supported: 'not there'.
        K.W32(K.Arg(0) + 36, 0);
        K.Warn(Format('sceSifBindRpc from IOP for %.8x', [K.Arg(1)]));
      end;
    16: Result := Cardinal(-1);
    17: K.RegisterServer(K.Arg(0), K.Arg(1), K.Arg(2), K.Arg(3), K.Arg(4), K.Arg(5), K.Arg(6));
    19: K.SetQueue(K.Arg(0), Integer(K.Arg(1)));
    20: Result := K.TakeRequest(K.Arg(0));
    21: K.ExecRequest(K.Arg(0));
    22:
      begin
        var T := K.CurrentThread;
        if T > 0 then
        begin
          K.Threads[T].RpcQueue := K.Arg(0);
          var Next := K.NextRequest(K.Arg(0));
          if Next >= 0 then
            K.StartRequest(T, Next)
          else
            K.Block(WaitRpc, 0, K.Arg(0));
        end;
      end;
    23:
      begin
        // sceSifGetOtherData(rd, src (EE), dest (IOP), size, mode)
        var Src := K.Arg(1) and PS2RAMMask;
        var Size := Integer(K.Arg(3));
        for var I := 0 to Size - 1 do
          K.W8(K.Arg(2) + Cardinal(I), K.EERAM[(Src + Cardinal(I)) and PS2RAMMask]);
      end;
  end;
end;

function TimrmanCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  var Id := Integer(K.Arg(0)) - 1;
  var Valid := (Id >= 0) and (Id <= High(K.Timers)) and K.Timers[Id].Used;
  case Fn of
    4:
      begin
        for var I := 0 to High(K.Timers) do
          if not K.Timers[I].Used then
          begin
            K.Timers[I] := Default(TIOPHardTimer);
            K.Timers[I].Used := True;
            K.Timers[I].Source := K.Arg(0);
            K.Timers[I].Prescale := Max(K.Arg(2), 1);
            Exit(Cardinal(I + 1));
          end;
        Result := Cardinal(-1);
      end;
    6:
      if Valid then
        K.Timers[Id].Used := False;
    10:
      if Valid then
        Result := Cardinal((K.CPU.Cycles * 8 div K.TimerCycles(Id, 1)) and $FFFFFFFF);
    11:
      if Valid then
        K.Timers[Id].Compare := K.Arg(1);
    12:
      if Valid then
        Result := K.Timers[Id].Compare;
    16:
      if Valid then
        Result := Cardinal(4 + Id);
    20:
      if Valid then
      begin
        K.Timers[Id].Compare := K.Arg(1);
        K.Timers[Id].Handler := K.Arg(2);
        K.Timers[Id].Arg := K.Arg(3);
        K.Timers[Id].Running := K.Arg(2) <> 0;
        K.Timers[Id].Next := K.CPU.Cycles * 8 + K.TimerCycles(Id, Max(K.Arg(1), 1));
        K.ScheduleTimers;
      end;
    22:
      // SetupHardTimer(timid, source, mode, prescale).
      if Valid then
      begin
        K.Timers[Id].Source := K.Arg(1);
        K.Timers[Id].Prescale := Max(K.Arg(3), 1);
      end;
    23:
      if Valid then
      begin
        K.Timers[Id].Running := True;
        K.Timers[Id].Next := K.CPU.Cycles * 8 + K.TimerCycles(Id, Max(K.Timers[Id].Compare, 1));
        K.ScheduleTimers;
      end;
    24:
      if Valid then
        K.Timers[Id].Running := False;
  end;
end;

function VblankCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    4: K.Block(WaitVblankStart);
    5: K.Block(WaitVblankEnd);
    6:
      if not K.InVblank then
        K.Block(WaitVblankStart);
    7:
      if K.InVblank then
        K.Block(WaitVblankEnd);
    8:
      for var I := 0 to High(K.Vblanks) do
        if not K.Vblanks[I].Used then
        begin
          K.Vblanks[I].Used := True;
          K.Vblanks[I].Edge := Integer(K.Arg(0));
          K.Vblanks[I].Priority := Integer(K.Arg(1));
          K.Vblanks[I].Handler := K.Arg(2);
          K.Vblanks[I].Arg := K.Arg(3);
          Break;
        end;
    9:
      for var I := 0 to High(K.Vblanks) do
        if K.Vblanks[I].Used and (K.Vblanks[I].Edge = Integer(K.Arg(0))) and (K.Vblanks[I].Handler = K.Arg(1)) then
          K.Vblanks[I].Used := False;
  end;
end;

function DmaChannelAddress(Ch: Cardinal): Cardinal;
begin
  if Ch < 7 then
    Result := $1F801080 + Ch * 16
  else
    Result := $1F801500 + (Ch - 7) * 16;
end;

function DmacmanCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  var Ch := K.Arg(0);
  case Fn of
    4, 6, 8, 10:
      K.Hardware.Write(DmaChannelAddress(Ch) + Cardinal(Fn - 4) * 2, K.Arg(1), 4);
    5, 7, 9, 11:
      Result := K.Hardware.Read(DmaChannelAddress(Ch) + Cardinal(Fn - 5) * 2, 4);
    14: K.Hardware.Write($1F8010F0, K.Arg(0), 4);
    15: Result := K.Hardware.Read($1F8010F0, 4);
    16: K.Hardware.Write($1F801570, K.Arg(0), 4);
    17: Result := K.Hardware.Read($1F801570, 4);
    20: K.Hardware.Write($1F8010F4, K.Arg(0), 4);
    21: Result := K.Hardware.Read($1F8010F4, 4);
    22: K.Hardware.Write($1F801574, K.Arg(0), 4);
    23: Result := K.Hardware.Read($1F801574, 4);
    28:
      begin
        // sceSetSliceDMA(ch, madr, size (words), count, dir)
        K.Hardware.Write(DmaChannelAddress(Ch), K.Arg(1), 4);
        K.Hardware.Write(DmaChannelAddress(Ch) + 4, (K.Arg(3) shl 16) or (K.Arg(2) and $FFFF), 4);
        Result := 1;
      end;
    32:
      begin
        var A := DmaChannelAddress(Ch) + 8;
        K.Hardware.Write(A, K.Hardware.Read(A, 4) or $01000000, 4);
        Result := 1;
      end;
  end;
end;

function BCD(V: Integer): Byte;
begin
  Result := Byte(((V div 10) shl 4) or (V mod 10));
end;

function CdSearch(K: TPS2IOPKernel; FileAddress, NameAddress: Cardinal): Cardinal;
var
  E: TISO9660Entry;
begin
  var Name := K.ReadString(NameAddress, 256);
  var Clean := Name;
  var Semi := Clean.IndexOf(';');
  if Semi >= 0 then
    Clean := Clean.Substring(0, Semi);
  if (K.DiscFS = nil) or (K.DiscFS.ISO = nil) or not K.DiscFS.ISO.Find(Clean, E) or E.Directory then
  begin
    K.Warn('cdvd search ' + Name + ': not found');
    Exit(0);
  end;
  K.W32(FileAddress, Cardinal(E.LBA));
  K.W32(FileAddress + 4, Cardinal(E.Size));
  var Base := ExtractFileName(Clean.Replace('/', '\')) + ';1';
  for var I := 0 to 15 do
    if I < Length(Base) then
      K.W8(FileAddress + 8 + Cardinal(I), Byte(Base[I + 1]))
    else
      K.W8(FileAddress + 8 + Cardinal(I), 0);
  Result := 1;
end;

procedure CdReadSectors(K: TPS2IOPKernel; LBA: Int64; Count: Integer; Dest: Cardinal; SectorSize: Integer);
begin
  if (K.DiscFS = nil) or (K.DiscFS.Image = nil) or (Count <= 0) or (Count > 4096) then
    Exit;
  var Buf: TBytes;
  SetLength(Buf, Count * DVDSectorSize);
  K.DiscFS.Image.ReadSectors(LBA, Count, @Buf[0]);
  for var S := 0 to Count - 1 do
    for var I := 0 to Min(SectorSize, DVDSectorSize) - 1 do
      K.W8(Dest + Cardinal(S * SectorSize + I), Buf[S * DVDSectorSize + I]);
end;

function CdvdmanCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 1;
  var Busy := K.CdDoneAt > 0;
  case Fn of
    6, 62:
      begin
        // sceCdRead(lsn, sectors, buf, mode)
        var Count := Integer(K.Arg(1));
        var Size := 2048;
        if K.Arg(3) <> 0 then
          if K.R8(K.Arg(3) + 2) = 1 then
            Size := 2328
          else if K.R8(K.Arg(3) + 2) = 2 then
            Size := 2340;
        CdReadSectors(K, K.Arg(0), Count, K.Arg(2), Size);
        if K.Log <> nil then
          K.Warn(Format('sceCdRead %d x%d -> %.6x', [K.Arg(0), Count, K.Arg(2)]));
        K.CdLastCommand := 1;
        K.CdDoneAt := K.CPU.Cycles * 8 + Max(Int64(Count) * (PS2EEClock div 1800), 20000);
        K.ScheduleTimers;
      end;
    8: Result := 0;
    10, 87: Result := CdSearch(K, K.Arg(0), K.Arg(1));
    11:
      if (K.Arg(0) and 1) <> 0 then
        Result := Ord(Busy)
      else
      begin
        Result := 0;
        if Busy then
          K.Block(WaitCd);
      end;
    12:
      if (K.DiscFS <> nil) and (K.DiscFS.Image is TDVDCDImage) then
        Result := $12
      else
        Result := $14;
    13:
      if Busy then
        Result := 6
      else
        Result := 2;
    14:
      if K.Arg(1) <> 0 then
        K.W32(K.Arg(1), 0);
    16:
      begin
        var P := K.Arg(0);
        var M := (K.R8(P) shr 4) * 10 + (K.R8(P) and 15);
        var S := (K.R8(P + 1) shr 4) * 10 + (K.R8(P + 1) and 15);
        var F := (K.R8(P + 2) shr 4) * 10 + (K.R8(P + 2) and 15);
        Result := Cardinal((M * 60 + S) * 75 + F - 150);
      end;
    17:
      begin
        var L := Integer(K.Arg(0)) + 150;
        var P := K.Arg(1);
        K.W8(P, BCD(L div 4500));
        K.W8(P + 1, BCD((L div 75) mod 60));
        K.W8(P + 2, BCD(L mod 75));
        K.W8(P + 3, 0);
      end;
    21: Result := Ord(not Busy);
    24:
      begin
        var P := K.Arg(0);
        var T := Now;
        var Y, Mo, D, H, Mi, S, Ms: Word;
        DecodeDate(T, Y, Mo, D);
        DecodeTime(T, H, Mi, S, Ms);
        K.W8(P, 0);
        K.W8(P + 1, BCD(S));
        K.W8(P + 2, BCD(Mi));
        K.W8(P + 3, BCD(H));
        K.W8(P + 4, 0);
        K.W8(P + 5, BCD(D));
        K.W8(P + 6, BCD(Mo));
        K.W8(P + 7, BCD(Y mod 100));
      end;
    28:
      if Busy then
        Result := 6
      else
        Result := $0A;
    37:
      begin
        Result := K.CdCallback;
        K.CdCallback := K.Arg(0);
      end;
    44: Result := 0;
    // sceCdSC/sceCdRC: secret commands; a retail console answers 0 (God of
    // War II's check module treats 1 as an unsupported unit).
    50, 51: Result := 0;
    56: Result := 1;
    57:
      begin
        // sceCdStRead(sectors, buf, mode, *err)
        var Count := Integer(K.Arg(0));
        CdReadSectors(K, K.CdStreamLBA, Count, K.Arg(1), 2048);
        Inc(K.CdStreamLBA, Count);
        if K.Arg(3) <> 0 then
          K.W32(K.Arg(3), 0);
        Result := Cardinal(Count);
      end;
    58, 59: K.CdStreamLBA := K.Arg(0);
    60: Result := 64;
    79, 80:
      if K.Arg(0) <> 0 then
        K.W32(K.Arg(0), 0);
    86:
      begin
        if K.Arg(0) <> 0 then
          K.W32(K.Arg(0), 0);
        if K.Arg(1) <> 0 then
          K.W32(K.Arg(1), 0);
      end;
  end;
end;

function IomanCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    4:
      begin
        var Path := K.ReadString(K.Arg(0), 256);
        Result := Cardinal(K.IOMan.Open(Path, Integer(K.Arg(1))));
        if (K.Log <> nil) and not K.Logged($80000000 or (Cardinal(Path.GetHashCode) and $7FFFFFFF)) then
          K.Warn(Format('open %s (at %.8x) mode %x -> %d', [Path, K.Arg(0), K.Arg(1), Integer(Result)]));
      end;
    5: Result := Cardinal(K.IOMan.Close(Integer(K.Arg(0))));
    6:
      begin
        var Data: TBytes;
        var N := K.IOMan.Read(Integer(K.Arg(0)), Integer(K.Arg(2)), Data);
        for var I := 0 to Min(N, Length(Data)) - 1 do
          K.W8(K.Arg(1) + Cardinal(I), Data[I]);
        Result := Cardinal(N);
      end;
    7:
      begin
        var Data: TBytes;
        SetLength(Data, Max(Integer(K.Arg(2)), 0));
        for var I := 0 to Length(Data) - 1 do
          Data[I] := K.R8(K.Arg(1) + Cardinal(I));
        if K.Arg(0) <= 2 then
        begin
          K.Print(TEncoding.ANSI.GetString(Data));
          Result := Cardinal(Length(Data));
        end
        else
          Result := Cardinal(K.IOMan.Write(Integer(K.Arg(0)), Data));
      end;
    8: Result := Cardinal(K.IOMan.Seek(Integer(K.Arg(0)), Integer(K.Arg(1)), Integer(K.Arg(2))));
    16:
      begin
        var Size: Int64;
        Result := Cardinal(K.IOMan.GetStat(K.ReadString(K.Arg(0), 256), Size));
        if Integer(Result) >= 0 then
        begin
          var P := K.Arg(1);
          for var I := 0 to 63 do
            K.W8(P + Cardinal(I), 0);
          K.W32(P, $2000 or $0124);
          K.W32(P + 4, $27);
          K.W32(P + 8, Cardinal(Size));
        end;
      end;
  end;
end;

function ModloadLoad(K: TPS2IOPKernel; const Path: string; const Data: TBytes): Integer;
begin
  if Data = nil then
    Exit(-203);
  Result := K.LoadModule(Data, Path);
end;

function ModloadCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    6, 7:
      begin
        var Path := K.ReadString(K.Arg(0), 256);
        if K.IsHLEModule(Path, '') then
        begin
          if Assigned(K.OnHighLevelModule) then
            K.OnHighLevelModule(Path, nil);
          if (Fn = 7) and (K.Arg(3) <> 0) then
            K.W32(K.Arg(3), Ord(K.IsAbsentDevice(Path, '')));
          Exit(1000);
        end;
        var Device, P: string;
        TPS2IOMan.SplitPath(Path, Device, P);
        var Data: TBytes := nil;
        if K.IOMan.FileSystem <> nil then
          Data := K.IOMan.FileSystem.ReadFile(Device, P);
        var Id := ModloadLoad(K, Path, Data);
        if (Id > 0) and (Fn = 7) then
        begin
          var Args: TBytes;
          SetLength(Args, Max(Integer(K.Arg(1)), 0));
          for var I := 0 to Length(Args) - 1 do
            Args[I] := K.R8(K.Arg(2) + Cardinal(I));
          K.StartModule(Id, Path, Args, nil, K.CurrentThread, K.Arg(3));
          K.Block(WaitModule, Id);
        end;
        Result := Cardinal(Id);
      end;
    8:
      begin
        var Id := Integer(K.Arg(0));
        if Id >= 1000 then
        begin
          // A system module the high-level IOP provides.
          if K.Arg(4) <> 0 then
            K.W32(K.Arg(4), 0);
          Exit(Cardinal(Id));
        end;
        if (Id >= 1) and (Id <= High(K.Modules)) and K.Modules[Id].Used and not K.Modules[Id].Started then
        begin
          var Args: TBytes;
          SetLength(Args, Max(Integer(K.Arg(2)), 0));
          for var I := 0 to Length(Args) - 1 do
            Args[I] := K.R8(K.Arg(3) + Cardinal(I));
          K.StartModule(Id, K.ReadString(K.Arg(1), 256), Args, nil, K.CurrentThread, K.Arg(4));
          K.Block(WaitModule, Id);
          Result := Cardinal(Id);
        end
        else
          Result := Cardinal(KEUnknownModule);
      end;
    9, 10:
      begin
        var Data := K.ImageAt(K.Arg(0));
        var Info: TIRXInfo;
        if ParseIRX(Data, Info) and K.IsHLEModule('', Info.Name) then
        begin
          K.Warn('module ' + Info.Name + ' is high level');
          if Assigned(K.OnHighLevelModule) then
            K.OnHighLevelModule(Info.Name, Data);
          Exit(1000);
        end;
        Result := Cardinal(ModloadLoad(K, '', Data));
      end;
    22:
      begin
        var Name := K.ReadString(K.Arg(0), 64);
        Result := Cardinal(KEUnknownModule);
        for var I := 1 to High(K.Modules) do
          if K.Modules[I].Used and SameText(string(K.Modules[I].Name), Name) then
            Exit(Cardinal(I));
      end;
    23: Result := Cardinal(KEUnknownModule);
  end;
end;

function HeaplibCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    4: Result := K.Allocator.Allocate(16);
    5: K.Allocator.Release(K.Arg(0));
    6: Result := K.Allocator.Allocate(K.Arg(1));
    7: K.Allocator.Release(K.Arg(1));
    8: Result := K.Allocator.FreeTotal;
  end;
end;

// secrman: MagicGate is not emulated; card authentication
// (SecrAuthCard(port, slot, cnum), SIO2 port 2 or 3) succeeds when a card
// is in the port, the card driver's handlers are not needed, and the
// decryption functions fail.
function SecrmanCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    6:
      if K.Hardware.SIO2.CardPresent(Integer(K.Arg(0))) then
        Result := 1;
  end;
end;

procedure IOPLibraryCall(K: TPS2IOPKernel; Lib, Fn: Integer);
begin
  var V: Cardinal := 0;
  case Lib of
    LSysmem: V := SysmemCall(K, Fn);
    LLoadcore: V := LoadcoreCall(K, Fn);
    LIntrman: V := IntrmanCall(K, Fn);
    LThbase: V := ThbaseCall(K, Fn);
    LThevent: V := TheventCall(K, Fn);
    LThsema: V := ThsemaCall(K, Fn);
    LThmsgbx: V := ThmsgbxCall(K, Fn);
    LThfpool: V := PoolCall(K, Fn, False);
    LThvpool: V := PoolCall(K, Fn, True);
    LSysclib: V := SysclibCall(K, Fn);
    LStdio: V := StdioCall(K, Fn);
    LSifman: V := SifmanCall(K, Fn);
    LSifcmd: V := SifcmdCall(K, Fn);
    LTimrman: V := TimrmanCall(K, Fn);
    LVblank: V := VblankCall(K, Fn);
    LDmacman: V := DmacmanCall(K, Fn);
    LCdvdman: V := CdvdmanCall(K, Fn);
    LIoman, LIomanx: V := IomanCall(K, Fn);
    LModload: V := ModloadCall(K, Fn);
    LHeaplib: V := HeaplibCall(K, Fn);
    LSecrman: V := SecrmanCall(K, Fn);
  end;
  // A blocked call gets its result when the thread is woken.
  if (K.Current <= 0) or (K.Threads[K.Current].State = ThReady) then
    K.CPU.R[IOPRegV0] := V;
  if K.LibCallCounts <> nil then
  begin
    var Key := (Cardinal(Lib) shl 16) or Cardinal(Fn);
    var N: Int64;
    if not K.LibCallCounts.TryGetValue(Key, N) then
      N := 0;
    K.LibCallCounts.AddOrSetValue(Key, N + 1);
  end;
  if K.Log <> nil then
  begin
    var Key := (Cardinal(Lib) shl 16) or Cardinal(Fn);
    if not K.Logged(Key) then
      K.Warn(Format('call %s:%d', [LibNames[Lib], Fn]));
  end;
end;

end.
