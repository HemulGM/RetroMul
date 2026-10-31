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
  KEFoundHandler = -104;
  KENotFoundHandler = -105;
  KEIllegalIntrCode = -101;
  KEIllegalAttr = -401;
  KEIllegalEntry = -402;
  KEIllegalPriority = -403;
  KEIllegalStackSize = -404;
  KEIllegalThid = -406;
  KEUnknownThid = -407;
  KENotDormant = -414;
  KEDormant = -415;
  KENotWait = -416;
  KEWaitDelete = -425;
  KEError = -1;
  KENoMemory = -400;
  KEUnknownVplid = -411;
  KEIllegalMemsize = -427;
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
          // Zeros go after the sign.
          if (S <> '') and CharInSet(S[1], ['-', '+']) then
            S := S[1] + StringOfChar('0', Width - Length(S)) + Copy(S, 2, MaxInt)
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
      // RegisterIntrHandler: a null handler counts as none; a line keeps
      // the first real handler (KE_FOUND_HANDLER for another).
      if (Line < 0) or (Line > High(K.Intr)) then
        Result := Cardinal(KEIllegalIntrCode)
      else if K.Intr[Line].Registered and (K.Intr[Line].Handler <> 0) then
        Result := Cardinal(KEFoundHandler)
      else
      begin
        K.Intr[Line].Registered := K.Arg(2) <> 0;
        K.Intr[Line].Mode := K.Arg(1);
        K.Intr[Line].Handler := K.Arg(2);
        K.Intr[Line].Arg := K.Arg(3);
        // DMA lines are masked by the channel's own enable bit.
        if Line >= 32 then
          K.Intr[Line].Enabled := True;
      end;
    5:
      if (Line < 0) or (Line > High(K.Intr)) then
        Result := Cardinal(KEIllegalIntrCode)
      else if not K.Intr[Line].Registered or (K.Intr[Line].Handler = 0) then
        Result := Cardinal(KENotFoundHandler)
      else
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
        // CreateThread: attributes TH_C, TH_ASM and TH_UMODE (hardware
        // rejects TH_NO_FILLSTACK and TH_CLEAR_STACK too), priority 1..126,
        // a word-aligned entry and at least 130h bytes of stack.
        var P := K.Arg(0);
        var Attr := K.R32(P);
        var Entry := K.R32(P + 8);
        var Prio := K.R32(P + 16);
        var Stack := K.R32(P + 12);
        if (Attr and not Cardinal($03000008)) <> 0 then
          Result := Cardinal(KEIllegalAttr)
        else if (Prio < 1) or (Prio > 126) then
          Result := Cardinal(KEIllegalPriority)
        else if (Entry and 3) <> 0 then
          Result := Cardinal(KEIllegalEntry)
        else if Stack < $130 then
          Result := Cardinal(KEIllegalStackSize)
        else
          Result := Cardinal(K.CreateThread(Attr, Entry, Prio, Stack, K.R32(P + 4), K.CPU.R[IOPRegGP]));
        if K.Log <> nil then
          K.Warn(Format('CreateThread entry %.6x prio %d stack %x -> %d', [Entry, Prio, Stack, Integer(Result)]));
      end;
    5:
      if Id = 0 then
        Result := Cardinal(KEIllegalThid)
      else if not ValidThread(K, Id) then
        Result := Cardinal(KEUnknownThid)
      else if (Id = K.CurrentThread) or (K.Threads[Id].State <> ThDormant) then
        Result := Cardinal(KENotDormant)
      else
        K.DeleteThread(Id);
    6, 7:
      if Id = 0 then
        Result := Cardinal(KEIllegalThid)
      else if not ValidThread(K, Id) then
        Result := Cardinal(KEUnknownThid)
      else if (Id = K.CurrentThread) or (K.Threads[Id].State <> ThDormant) then
        Result := Cardinal(KENotDormant)
      else
        K.StartThread(Id, K.Arg(1), K.Arg(2), Fn = 7);
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
      if (Id = 0) or (Id = K.CurrentThread) then
        Result := Cardinal(KEIllegalThid)
      else if not ValidThread(K, Id) then
        Result := Cardinal(KEUnknownThid)
      else if K.Threads[Id].State = ThDormant then
        Result := Cardinal(KEDormant)
      else
      begin
        K.Threads[Id].State := ThDormant;
        K.Threads[Id].Wait := WaitNone;
      end;
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
      // ReleaseWaitThread: the waiting thread returns KE_RELEASE_WAIT.
      if (Id = 0) or (Id = K.CurrentThread) then
        Result := Cardinal(KEIllegalThid)
      else if not ValidThread(K, Id) then
        Result := Cardinal(KEUnknownThid)
      else if K.Threads[Id].State <> ThWaiting then
        Result := Cardinal(KENotWait)
      else
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
          // Wait type: sleep 1, delay 2, semaphore 3, event flag 4, message
          // box 5; the high-level waits are what the modules use there
          // (sleeping RPC loops, event flags for VBlank, CD and modules).
          var Wait: Cardinal := T.Wait;
          case T.Wait of
            WaitRpc: Wait := WaitSleep;
            WaitVblankStart, WaitVblankEnd, WaitCd, WaitModule: Wait := WaitEvent;
            // AllocateVpl reports the fixed-pool wait type (7), as the
            // threadman reference does.
            WaitVpl: Wait := 7;
          end;
          if T.State <> ThWaiting then
            Wait := 0;
          K.W32(I + 36, Wait);
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
      if (Id = 0) or (Id = K.CurrentThread) then
        Result := Cardinal(KEIllegalThid)
      else if not ValidThread(K, Id) then
        Result := Cardinal(KEUnknownThid)
      else if K.Threads[Id].State = ThDormant then
        Result := Cardinal(KEDormant)
      else if (K.Threads[Id].State = ThWaiting) and (K.Threads[Id].Wait = WaitSleep) then
        K.Wake(Id, 0)
      else
        Inc(K.Threads[Id].WakeupCount);
    27, 28:
      begin
        if Id = 0 then
          Id := K.CurrentThread;
        if ValidThread(K, Id) then
        begin
          Result := Cardinal(K.Threads[Id].WakeupCount);
          K.Threads[Id].WakeupCount := 0;
        end
        else
          Result := Cardinal(KEUnknownThid);
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
    5:
      begin
        // Threads waiting on it return KE_WAIT_DELETE.
        K.Events[Id].Used := False;
        for var T := 1 to IOPMaxThreads do
          if K.Threads[T].Used and (K.Threads[T].State = ThWaiting) and (K.Threads[T].Wait = WaitEvent) and
            (K.Threads[T].WaitId = Id) then
            K.Wake(T, Cardinal(KEWaitDelete));
      end;
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
        // A flag without the multiple-wait attribute that a thread waits on
        // takes neither a second waiter nor a poll.
        if (K.Events[Id].Attr and EventMulti) = 0 then
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
        K.W32(I + 16, Cardinal(K.WaiterCount(WaitEvent, Id)));
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
    5:
      begin
        // Threads waiting on it return KE_WAIT_DELETE.
        K.Mbxs[Id].Used := False;
        for var T := 1 to IOPMaxThreads do
          if K.Threads[T].Used and (K.Threads[T].State = ThWaiting) and (K.Threads[T].Wait = WaitMbx) and
            (K.Threads[T].WaitId = Id) then
            K.Wake(T, Cardinal(KEWaitDelete));
      end;
    6, 7: K.SendMessage(Id, K.Arg(1));
    8, 9:
      if K.Mbxs[Id].Count > 0 then
      begin
        var Msg := K.TakeMessage(Id);
        if K.Arg(0) <> 0 then
          K.W32(K.Arg(0), Msg);
      end
      else if Fn = 9 then
        Result := Cardinal(KEMboxNoMsg)
      else
        K.Block(WaitMbx, Id, K.Arg(0));
    11, 12:
      begin
        // ReferMbxStatus: attr, option, waiting threads, messages, top
        // message (reserved words untouched).
        var I := K.Arg(1);
        K.W32(I, K.Mbxs[Id].Attr);
        K.W32(I + 4, K.Mbxs[Id].Option);
        K.W32(I + 8, Cardinal(K.WaiterCount(WaitMbx, Id)));
        K.W32(I + 12, Cardinal(K.Mbxs[Id].Count));
        if K.Mbxs[Id].Head <> 0 then
          K.W32(I + 16, K.R32(K.Mbxs[Id].Head))
        else
          K.W32(I + 16, 0);
      end;
  end;
end;

{ heaplib }

// Heaps live in IOP memory laid out as SCE heaplib keeps them (behaviour
// after the ps2sdk reimplementation, AFL 2.0). A heap is a 16-byte header
// (key: its address + 1; growth size and allocation side; the ring of further
// chunks) followed by its first chunk. A chunk is a 16-byte header (key: its
// address - 1; size in bytes; 8-byte blocks in use; the free fragment the
// last search stopped at) and fragments with 8-byte headers (next, size in
// blocks). Free fragments form an address-ordered ring closed by an empty
// terminator at the chunk's end; used ones point at their chunk. Allocation
// searches the ring from where the last search stopped and takes the high
// end of the first fragment that fits; freeing merges with both neighbours.
const
  HeapRingGuard = 1 shl 20;

function HeapValid(K: TPS2IOPKernel; Heap: Cardinal): Boolean;
begin
  Result := (Heap <> 0) and (K.R32(Heap) = Add32(Heap, 1));
end;

function HeapChunkValid(K: TPS2IOPKernel; Chunk: Cardinal): Boolean;
begin
  Result := (Chunk <> 0) and (K.R32(Chunk) = Sub32(Chunk, 1));
end;

procedure HeapPrepare(K: TPS2IOPKernel; Chunk: Cardinal; Size: Integer);
begin
  // Smaller chunks (than a header, one fragment and the terminator) stay
  // unusable.
  if (Chunk = 0) or (Size < $29) then
    Exit;
  var Blocks := (Cardinal(Size) - 16) shr 3;
  var Last := Add32(Chunk, 8 + Blocks * 8);
  K.W32(Chunk, Chunk - 1);
  K.W32(Chunk + 4, Cardinal(Size));
  K.W32(Chunk + 8, 0);
  K.W32(Chunk + 12, Chunk + 16);
  K.W32(Chunk + 16, Last);
  K.W32(Chunk + 20, Blocks - 1);
  K.W32(Last, Chunk + 16);
  K.W32(Last + 4, 0);
end;

// Bytes of a chunk still free (its blocks less those in use and one header).
function HeapChunkFreeSize(K: TPS2IOPKernel; Chunk: Cardinal): Integer;
begin
  var Blocks := Int64(Sub32(K.R32(Chunk + 4), 16) shr 3) - Int64(K.R32(Chunk + 8)) - 1;
  Result := Integer((Blocks * 8) and $FFFFFFFF);
end;

// The payload of a new fragment of Bytes (at least 8, rounded up to 8, plus
// its header), or 0.
function HeapChunkAllocate(K: TPS2IOPKernel; Chunk, Bytes: Cardinal): Cardinal;
begin
  Result := 0;
  if not HeapChunkValid(K, Chunk) then
    Exit;
  var Need: Cardinal := 2;
  if Bytes >= 8 then
    Need := (Add32(Bytes, 7) shr 3) + 1;
  var Start := K.R32(Chunk + 12);
  var Prev := Start;
  var F := K.R32(Prev);
  var Guard := 0;
  while Integer(K.R32(F + 4)) < Integer(Need) do
  begin
    Prev := F;
    Inc(Guard);
    if (F = Start) or (Guard > HeapRingGuard) then
      Exit;
    F := K.R32(F);
  end;
  var Size := K.R32(F + 4);
  if Size = Need then
    K.W32(Prev, K.R32(F))
  else
  begin
    K.W32(F + 4, Size - Need);
    F := Add32(F, Cardinal((UInt64(Size - Need) * 8) and $FFFFFFFF));
    K.W32(F + 4, Need);
  end;
  K.W32(Chunk + 12, Prev);
  K.W32(F, Chunk);
  K.W32(Chunk + 8, Add32(K.R32(Chunk + 8), Need));
  Result := F + 8;
end;

// Returns a fragment to its chunk: 0, -1 (not a fragment of the chunk), -2
// (outside it), -3 (free already or overlapping free space), -4 (no chunk).
function HeapChunkFree(K: TPS2IOPKernel; Chunk, Ptr: Cardinal): Integer;
begin
  if not HeapChunkValid(K, Chunk) then
    Exit(-4);
  if Ptr = 0 then
    Exit(-1);
  var H := Sub32(Ptr, 8);
  var HSize := K.R32(H + 4);
  if (K.R32(H) <> Chunk) or (Integer(HSize) <= 0) then
    Exit(-1);
  if (H < Chunk + 16) or (Int64(H) >= Int64(Chunk) + K.R32(Chunk + 4)) then
    Exit(-2);
  // The free fragment H follows in the ring (the highest one when H lies
  // below every free fragment).
  var F := K.R32(Chunk + 12);
  var Start := F;
  var Guard := 0;
  while True do
  begin
    if F = H then
      Exit(-3);
    var N := K.R32(F);
    if ((F < H) and (H < N)) or ((N <= F) and ((H > F) or (H < N))) then
      Break;
    F := N;
    Inc(Guard);
    if (F = Start) or (Guard > HeapRingGuard) then
      Exit(-3);
  end;
  var Next := K.R32(F);
  var HEnd := Int64(H) + Int64(HSize) * 8;
  if (H < Next) and (Int64(Next) < HEnd) then
    Exit(-3);
  if (F < H) and (Int64(H) < Int64(F) + Int64(K.R32(F + 4)) * 8) then
    Exit(-3);
  K.W32(Chunk + 8, Sub32(K.R32(Chunk + 8), HSize));
  if (HEnd = Next) and (Integer(K.R32(Next + 4)) > 0) then
  begin
    HSize := Add32(HSize, K.R32(Next + 4));
    K.W32(H + 4, HSize);
    K.W32(H, K.R32(Next));
  end
  else
    K.W32(H, Next);
  if Int64(H) = Int64(F) + Int64(K.R32(F + 4)) * 8 then
  begin
    K.W32(F + 4, Add32(K.R32(F + 4), HSize));
    K.W32(F, K.R32(H));
  end
  else
    K.W32(F, H);
  K.W32(Chunk + 12, F);
  Result := 0;
end;

// A heap of Size bytes (rounded up to 4) from system memory: Flag bit 0
// lets it grow by further chunks of that size, bit 1 takes memory from the
// top. 0 when there is no memory.
function HeapCreate(K: TPS2IOPKernel; Size: Integer; Flag: Cardinal): Cardinal;
begin
  Result := 0;
  var Bytes := (Int64(Size) + 3) and not Int64(3);
  if (Bytes <= 0) or (Bytes > PS2IOPRAMSize) then
    Exit;
  var Top := (Flag shr 1) and 1;
  Result := K.Allocator.AllocateMode(Top, Cardinal(Bytes), 0);
  if Result = 0 then
    Exit;
  var Grow: Cardinal := 0;
  if (Flag and 1) <> 0 then
    Grow := Cardinal(Bytes);
  K.W32(Result, Result + 1);
  K.W32(Result + 4, Grow or Top);
  K.W32(Result + 8, Result + 8);
  K.W32(Result + 12, Result + 8);
  HeapPrepare(K, Result + 16, Integer(Bytes) - 16);
end;

procedure HeapDelete(K: TPS2IOPKernel; Heap: Cardinal);
begin
  if not HeapValid(K, Heap) then
    Exit;
  var Head := Heap + 8;
  var Item := K.R32(Head);
  K.W32(Heap, 0);
  var Guard := 0;
  while (Item <> Head) and (Guard < 4096) do
  begin
    var Next := K.R32(Item);
    K.W32(Item + 8, 0);
    K.Allocator.Release(Item);
    Item := Next;
    Inc(Guard);
  end;
  K.W32(Heap + 16, 0);
  K.Allocator.Release(Heap);
end;

function HeapAllocate(K: TPS2IOPKernel; Heap, Bytes: Cardinal): Cardinal;
begin
  Result := 0;
  if not HeapValid(K, Heap) then
    Exit;
  var Head := Heap + 8;
  var Item := K.R32(Head);
  var Guard := 0;
  while True do
  begin
    Result := HeapChunkAllocate(K, Add32(Item, 8), Bytes);
    if Result <> 0 then
      Exit;
    Inc(Guard);
    if (Item = Head) or (Guard > 4096) then
      Break;
    Item := K.R32(Item);
  end;
  // A growing heap takes another chunk (its size, or what the request needs)
  // and links it first.
  var Flags := K.R32(Heap + 4);
  if Flags < 4 then
    Exit(0);
  var Size := Flags and not Cardinal(1);
  if Integer(Sub32(Size, 40)) < Integer(Bytes) then
    Size := Add32(Bytes, 40);
  if Size > PS2IOPRAMSize then
    Exit(0);
  var New := K.Allocator.AllocateMode(Flags and 1, Size, 0);
  if New = 0 then
    Exit(0);
  var First := K.R32(Head);
  K.W32(New, First);
  K.W32(New + 4, K.R32(First + 4));
  K.W32(First + 4, New);
  K.W32(K.R32(New + 4), New);
  HeapPrepare(K, New + 8, Integer(K.Allocator.BlockSize(New)) - 8);
  Result := HeapChunkAllocate(K, New + 8, Bytes);
end;

// 0, -1 (not in the heap) or -4 (no heap); an emptied further chunk goes
// back to system memory.
function HeapRelease(K: TPS2IOPKernel; Heap, Ptr: Cardinal): Integer;
begin
  if not HeapValid(K, Heap) then
    Exit(-4);
  var Head := Heap + 8;
  var Item := K.R32(Head);
  var Guard := 0;
  while HeapChunkFree(K, Add32(Item, 8), Ptr) <> 0 do
  begin
    Inc(Guard);
    if (Item = Head) or (Guard > 4096) then
      Exit(-1);
    Item := K.R32(Item);
  end;
  if (Item <> Head) and HeapChunkValid(K, Item + 8) and (K.R32(Item + 16) = 0) then
  begin
    K.W32(K.R32(Item) + 4, K.R32(Item + 4));
    K.W32(K.R32(Item + 4), K.R32(Item));
    K.W32(Item + 8, 0);
    K.Allocator.Release(Item);
  end;
  Result := 0;
end;

// The free bytes of all chunks; -4 without a heap.
function HeapFreeTotal(K: TPS2IOPKernel; Heap: Cardinal): Integer;
begin
  if not HeapValid(K, Heap) then
    Exit(-4);
  var Head := Heap + 8;
  var Item := K.R32(Head);
  var Total: Int64 := 0;
  var Guard := 0;
  while True do
  begin
    Inc(Total, HeapChunkFreeSize(K, Add32(Item, 8)));
    Inc(Guard);
    if (Item = Head) or (Guard > 4096) then
      Break;
    Item := K.R32(Item);
  end;
  Result := Integer(Total and $FFFFFFFF);
end;

// Fixed-size block pools.
function PoolCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
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
        K.Pools[S].Blocks := K.R32(P + 12);
        Result := Cardinal(S);
      end;
    5:
      if ValidId(Integer(K.Arg(0))) and not K.Pools[Integer(K.Arg(0))].Variable then
        K.Pools[Integer(K.Arg(0))].Used := False;
    6, 7, 8:
      begin
        var Id := Integer(K.Arg(0));
        if not (ValidId(Id) and K.Pools[Id].Used and not K.Pools[Id].Variable) then
          Exit(0);
        Result := K.Allocator.Allocate(K.Pools[Id].BlockSize);
      end;
    9: K.Allocator.Release(K.Arg(1));
  end;
end;

// Variable pools (thvpool): a heap without growth per pool. The size checks
// use the free size the pool started with; a pool whose heap got no memory
// exists with size and free size -4 and allocates nothing.
function VplCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
const
  VplAttrs = $201; // VA_THPRI, VA_MEMBTM
begin
  Result := 0;
  var Id := Integer(K.Arg(0));
  if Fn <> 4 then
    if not (ValidId(Id) and K.Pools[Id].Used and K.Pools[Id].Variable) then
      Exit(Cardinal(KEUnknownVplid));
  case Fn of
    4:
      begin
        var P := K.Arg(0);
        var Attr := K.R32(P);
        var Size := Integer(K.R32(P + 8));
        if (Attr and not Cardinal(VplAttrs)) <> 0 then
          Exit(Cardinal(KEIllegalAttr));
        if Size = 0 then
          Exit(Cardinal(KEIllegalMemsize));
        var S := FreeSlot(K, 3);
        if S < 0 then
          Exit(Cardinal(KENoMemory));
        K.Pools[S] := Default(TIOPPool);
        K.Pools[S].Used := True;
        K.Pools[S].Variable := True;
        K.Pools[S].Attr := Attr;
        K.Pools[S].Option := K.R32(P + 4);
        K.Pools[S].Heap := HeapCreate(K, Size, (Attr and $200) shl 1);
        K.Pools[S].InitialFree := HeapFreeTotal(K, K.Pools[S].Heap);
        Result := Cardinal(S);
      end;
    5:
      begin
        // Threads waiting on it return KE_WAIT_DELETE.
        for var T := 1 to IOPMaxThreads do
          if K.Threads[T].Used and (K.Threads[T].State = ThWaiting) and (K.Threads[T].Wait = WaitVpl) and
            (K.Threads[T].WaitId = Id) then
            K.Wake(T, Cardinal(KEWaitDelete));
        HeapDelete(K, K.Pools[Id].Heap);
        K.Pools[Id].Used := False;
      end;
    6, 7:
      begin
        // AllocateVpl waits for memory, pAllocateVpl does not.
        var Size := Integer(K.Arg(1));
        if (Size = 0) or (K.Pools[Id].InitialFree < Size) then
          Exit(Cardinal(KEIllegalMemsize));
        Result := HeapAllocate(K, K.Pools[Id].Heap, Cardinal(Size));
        if Result = 0 then
          if Fn = 7 then
            Result := Cardinal(KENoMemory)
          else
            K.Block(WaitVpl, Id, Cardinal(Size));
      end;
    8:
      begin
        Result := HeapAllocate(K, K.Pools[Id].Heap, K.Arg(1));
        if Result = 0 then
          Result := Cardinal(KENoMemory);
      end;
    9:
      begin
        // FreeVpl: the first waiter gets its memory if it fits now.
        if HeapRelease(K, K.Pools[Id].Heap, K.Arg(1)) < 0 then
          Exit(Cardinal(KEError));
        var T := K.FirstWaiter(WaitVpl, Id, (K.Pools[Id].Attr and 1) <> 0);
        if T > 0 then
        begin
          var Mem := HeapAllocate(K, K.Pools[Id].Heap, K.Threads[T].WaitA);
          if Mem <> 0 then
            K.Wake(T, Mem);
        end;
      end;
    11, 12:
      begin
        // ReferVplStatus: attr, option, size (the free size at creation),
        // free size, waiting threads; reserved words untouched.
        var I := K.Arg(1);
        K.W32(I, K.Pools[Id].Attr);
        K.W32(I + 4, K.Pools[Id].Option);
        K.W32(I + 8, Cardinal(K.Pools[Id].InitialFree));
        K.W32(I + 12, Cardinal(HeapFreeTotal(K, K.Pools[Id].Heap)));
        K.W32(I + 16, Cardinal(K.WaiterCount(WaitVpl, Id)));
      end;
  end;
end;

function SysclibCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  var A0 := K.Arg(0);
  var A1 := K.Arg(1);
  var A2 := K.Arg(2);
  case Fn of
    8:
      // look_ctype_table(c): the classes of an ASCII character (upper 01h,
      // lower 02h, digit 04h, space 08h, punctuation 10h, control 20h, hex
      // 40h); space is also punctuation, tab..CR only space.
      case Byte(A0) of
        9..13: Result := $08;
        32: Result := $18;
        Ord('0')..Ord('9'): Result := $04;
        Ord('A')..Ord('F'): Result := $41;
        Ord('G')..Ord('Z'): Result := $01;
        Ord('a')..Ord('f'): Result := $42;
        Ord('g')..Ord('z'): Result := $02;
        0..8, 14..31, 127: Result := $20;
        33..47, 58..64, 91..96, 123..126: Result := $10;
      else
        Result := 0;
      end;
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
    // _wmemcopy / _wmemset: whole 32-bit words, size in bytes (the remainder
    // below a word is left alone).
    40:
      begin
        for var I := 0 to Integer(A2 shr 2) - 1 do
          K.W32(A0 + Cardinal(I) * 4, K.R32(A1 + Cardinal(I) * 4));
        Result := A0;
      end;
    41:
      begin
        for var I := 0 to Integer(A2 shr 2) - 1 do
          K.W32(A0 + Cardinal(I) * 4, A1);
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
    // strspn(s, accept): length of the leading run of characters in accept.
    33:
      begin
        var Accept := K.ReadString(A1, 256);
        while (K.R8(A0 + Result) <> 0) and (Pos(Char(K.R8(A0 + Result)), Accept) > 0) do
          Inc(Result);
      end;
    // strtok(s, delim): the next token of s (or of the string the last call
    // stopped in when s is NULL), ended in place by a zero byte.
    35:
      begin
        var Delim := K.ReadString(A1, 256);
        var P := A0;
        if P = 0 then
          P := K.StrtokNext;
        Result := 0;
        if P <> 0 then
        begin
          while (K.R8(P) <> 0) and (Pos(Char(K.R8(P)), Delim) > 0) do
            Inc(P);
          if K.R8(P) = 0 then
            K.StrtokNext := 0
          else
          begin
            Result := P;
            while (K.R8(P) <> 0) and (Pos(Char(K.R8(P)), Delim) = 0) do
              Inc(P);
            if K.R8(P) <> 0 then
            begin
              K.W8(P, 0);
              K.StrtokNext := P + 1;
            end
            else
              K.StrtokNext := 0;
          end;
        end;
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
    33, 34, 35:
      if Ch <= 12 then
      begin
        // sceSetDMAPriority(ch, priority), sceEnableDMAChannel(ch),
        // sceDisableDMAChannel(ch): the channel's nibble of DPCR (0..6) or
        // DPCR2 (7..12), priority in bits 0-2, enable in bit 3.
        var Reg: Cardinal := $1F8010F0;
        var Shift := Integer(Ch) * 4;
        if Ch >= 7 then
        begin
          Reg := $1F801570;
          Shift := (Integer(Ch) - 7) * 4;
        end;
        var V := Cardinal(K.Hardware.Read(Reg, 4));
        case Fn of
          33: V := (V and not (Cardinal(7) shl Shift)) or ((K.Arg(1) and 7) shl Shift);
          34: V := V or (Cardinal(8) shl Shift);
          35: V := V and not (Cardinal(8) shl Shift);
        end;
        K.Hardware.Write(Reg, V, 4);
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

function CdSearch(K: TPS2IOPKernel; FileAddress, NameAddress: Cardinal; Layer: Integer): Cardinal;
var
  E: TISO9660Entry;
begin
  var Name := K.ReadString(NameAddress, 256);
  var Clean := Name;
  var Semi := Clean.IndexOf(';');
  if Semi >= 0 then
    Clean := Clean.Substring(0, Semi);
  if (K.DiscFS = nil) or not K.DiscFS.SearchLayer(Clean, Layer, E) then
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
        K.CdReadBytes := Count * Size;
        K.CdLastCommand := 1;
        K.CdDoneAt := K.CPU.Cycles * 8 + Max(Int64(Count) * (PS2EEClock div 1800), 20000);
        K.ScheduleTimers;
      end;
    8: Result := 0;
    // sceCdSearchFile (layer 0), sceCdLayerSearchFile(fp, name, layer).
    10:
      Result := CdSearch(K, K.Arg(0), K.Arg(1), 0);
    84:
      Result := CdSearch(K, K.Arg(0), K.Arg(1), Integer(K.Arg(2)));
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
        // sceCdReadClock: the same emulated clock as the EE's CDVD RPC and
        // memory cards, not host time (runs and snapshots must repeat).
        var T := PS2ClockAt(K.EETime);
        K.W8(P, 0);
        K.W8(P + 1, PS2BCD(T.Second));
        K.W8(P + 2, PS2BCD(T.Minute));
        K.W8(P + 3, PS2BCD(T.Hour));
        K.W8(P + 4, 0);
        K.W8(P + 5, PS2BCD(T.Day));
        K.W8(P + 6, PS2BCD(T.Month));
        K.W8(P + 7, PS2BCD(T.Year mod 100));
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
    // sceCdGetReadPos: the data of a read is there as soon as it starts.
    44: Result := Cardinal(K.CdReadBytes);
    // sceCdStandby, sceCdSeek, sceCdStop, sceCdPause, sceCdBreak: commands
    // that end a little later, with the callback (SCECdFuncStandby 5,
    // SCECdFuncSeek 4, SCECdFuncStop 6, SCECdFuncPause 7, SCECdFuncBreak 8).
    // A break ends a read at once; the others wait for a command running.
    5, 7, 15, 38, 39:
      if Busy and (Fn <> 39) then
        Result := 0
      else
      begin
        case Fn of
          5: K.CdLastCommand := 5;
          7: K.CdLastCommand := 4;
          15: K.CdLastCommand := 6;
          38: K.CdLastCommand := 7;
        else
          K.CdLastCommand := 8;
        end;
        K.CdDoneAt := K.CPU.Cycles * 8 + PS2EEClock div 1000;
        K.ScheduleTimers;
      end;
    // sceCdSC/sceCdRC: secret commands; a retail console answers 0 (God of
    // War II's check module treats 1 as an unsupported unit).
    50, 51: Result := 0;
    // sceCdStInit(bufmax, bankmax, buffer): the stream reads the disc when
    // read, so its buffer is always full (sceCdStStat).
    56:
      begin
        K.CdStreamSectors := Integer(K.Arg(0));
        Result := 1;
      end;
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
    60: Result := Cardinal(K.CdStreamSectors);
    79, 80:
      if K.Arg(0) <> 0 then
        K.W32(K.Arg(0), 0);
    // sceCdReadDvdDualInfo(on_dual, layer1_start).
    83:
      begin
        var Break_: Int64 := 0;
        if (K.DiscFS <> nil) and (K.DiscFS.Image <> nil) then
          Break_ := K.DiscFS.Image.LayerBreak;
        if K.Arg(0) <> 0 then
          K.W32(K.Arg(0), Ord(Break_ > 0));
        if K.Arg(1) <> 0 then
          K.W32(K.Arg(1), Cardinal(Break_));
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
    17:
      begin
        // ReferModuleStatus(id, status): name[56], version, flags, id,
        // entry, gp, text address and size, data size, bss size.
        var Id := Integer(K.Arg(0));
        var P := K.Arg(1);
        if (Id < 1) or (Id > High(K.Modules)) or not K.Modules[Id].Used then
          Exit(Cardinal(KEUnknownModule));
        var M := K.Modules[Id];
        for var I := 0 to 55 do
          if I < Length(M.Name) then
            K.W8(P + Cardinal(I), Byte(M.Name[I]))
          else
            K.W8(P + Cardinal(I), 0);
        K.W8(P + 55, 0);
        K.W16(P + 56, M.Version);
        K.W16(P + 58, 0);
        K.W32(P + 60, Cardinal(Id));
        K.W32(P + 64, M.Entry);
        K.W32(P + 68, M.GP);
        K.W32(P + 72, M.Base);
        K.W32(P + 76, M.TextSize);
        K.W32(P + 80, M.DataSize);
        K.W32(P + 84, M.BssSize);
        Result := 0;
      end;
  end;
end;

function HeaplibCall(K: TPS2IOPKernel; Fn: Integer): Cardinal;
begin
  Result := 0;
  case Fn of
    4: Result := HeapCreate(K, Integer(K.Arg(0)), K.Arg(1));
    5: HeapDelete(K, K.Arg(0));
    6: Result := HeapAllocate(K, K.Arg(0), K.Arg(1));
    7: Result := Cardinal(HeapRelease(K, K.Arg(0), K.Arg(1)));
    8: Result := Cardinal(HeapFreeTotal(K, K.Arg(0)));
    11: HeapPrepare(K, K.Arg(0), Integer(K.Arg(1)));
    12: Result := Ord(HeapChunkValid(K, K.Arg(0)) and (K.R32(K.Arg(0) + 8) = 0));
    13: Result := HeapChunkAllocate(K, K.Arg(0), K.Arg(1));
    14: Result := Cardinal(HeapChunkFree(K, K.Arg(0), K.Arg(1)));
    15: Result := Cardinal(HeapChunkFreeSize(K, K.Arg(0)));
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
    LThfpool: V := PoolCall(K, Fn);
    LThvpool: V := VplCall(K, Fn);
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
