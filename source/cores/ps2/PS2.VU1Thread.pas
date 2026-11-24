unit PS2.VU1Thread;

// Experimental: the VU1 domain's events on a thread of their own, ahead of
// the EE. The thread runs Step until told to stop or Step has nothing to do;
// it publishes the time up to which the domain is complete (Complete) and
// the time of the last event it ran (Last). What the domain does to the EE
// comes as outputs with their time; questions it has for the GS side
// (Request) wait for the EE to answer them. What it reads from memory it
// reads from a copy (ReadCopy), which the EE side compares with memory once
// it reaches the read's time (CheckReads). Copies and answers are kept while
// the domain runs ahead (a session): going back to where the session began,
// the domain does its events again from them (BeginReplay).
{$IFDEF PS2_CHECKED}
  {$Q+}
  {$R+}
{$ELSE}
  {$O+}
  {$Q-}
  {$R-}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Diagnostics,
  System.Generics.Collections, PS2.VU1Domain;

type
  TPS2AheadStep = (asDone, asIdle, asEnd);

  TPS2DomainOutput = record
    Time: Int64;
    Kind: Integer;
    Value: Cardinal;
  end;

  // A read of memory made running ahead: its time, the device (Key), where,
  // its copy, the bytes copied and those the device took (-1: not known yet).
  // Or (Check) a decision from an EE-side register at Source: whether it is
  // Value in the MFIFO ring (Mask, Offset); Expect: what was decided.
  // A read is posted before memory is looked at and Ready once its copy (or
  // decision) is made: the EE side at the read's time waits for that, so
  // what it wrote before is in the copy or is found to differ from it.
  TPS2DomainRead = record
    Time: Int64;
    Source, Data: PByte;
    Size, Used, Key: Integer;
    Mask, Offset, Value: Cardinal;
    Check, Expect: Boolean;
    Ready: Integer;
  end;

  PPS2DomainRead = ^TPS2DomainRead;

  // An answer the EE side gave the domain.
  TPS2DomainAnswer = record
    Time, Value: Int64;
    Kind: Integer;
  end;

  // What a device left of its last copy (Kept): where it goes on in memory
  // and in the copy, its bytes; the bytes its next copy may have (0: least).
  TPS2ReadTail = record
    Kept: Boolean;
    Source, Data: PByte;
    Size, Chunk: Integer;
  end;

  PPS2ReadTail = ^TPS2ReadTail;

  // A replay that does not read or ask as the session did.
  EPS2Replay = class(Exception);

  // The EE side applying an output, answering a question.
  TPS2DomainApply = procedure(Kind: Integer; Value: Cardinal) of object;

  TPS2DomainServe = function(Kind: Integer; Time: Int64): Int64 of object;

  TPS2VU1Thread = class(TThread)
  private
    const
      OutSize = 1 shl 14;
      SpinRounds = 4000;
      // Reads are kept in blocks of ReadBlock, copies in blocks of CopyBlock
      // bytes (a larger one in memory of its own); a session ends past
      // SessionReads reads or SessionBytes copied.
      ReadShift = 12;
      ReadBlock = 1 shl ReadShift;
      MaxReadBlocks = 1 shl 12;
      CopyBlock = 1 shl 22;
      KeptCopyBlocks = 4;
      SessionReads = 1 shl 20;
      SessionBytes = Int64(1) shl 28;
      // Bytes past a copy that a device may load (and not use).
      ReadSlack = 64;
      // Bytes a copy may have (ReadLimit).
      MinChunk = 256;
      MaxChunk = 1 shl 16;
    var
      FStep: TFunc<TPS2AheadStep>;
      FWake: TEvent;
      // 0 parked, 1 asked to run, 2 running; FStop asks it to park.
      FState, FStop, FEnded: Integer;
      FComplete, FLast: Int64;
      FOut: array[0..OutSize - 1] of TPS2DomainOutput;
      FOutPosted, FOutDone: Int64;
      FRequestPending, FRequestKind: Integer;
      FRequestTime, FRequestResult: Int64;
      FFailure: string;
      // Outputs and questions from now on are dropped (the domain goes back).
      FQuiet: Integer;
      // The session's reads (in blocks), posted and checked; a read whose
      // copy differed from memory at its time (High(Int64): none).
      FReadBlocks: array[0..MaxReadBlocks - 1] of PByte;
      FReadPosted, FReadChecked, FConflictAt: Int64;
      // Copies: blocks, the one in use (-1: none) and where in it; larger
      // copies; bytes in the session.
      FCopyBlocks, FCopyLarge: TList<PByte>;
      FCopyBlock, FCopyAt: Integer;
      FSessionBytes: Int64;
      FTails: array[0..4] of TPS2ReadTail;
      // The session's answers; replaying: the next read and answer.
      FAnswers: TList<TPS2DomainAnswer>;
      FReplaying: Boolean;
      FReplayRead, FReplayAnswer: Int64;
    function Read(Index: Int64): PPS2DomainRead; inline;
    function CopySpace(Need: Integer): PByte;
    function PostRead(Key: Integer; Time: Int64; Source, Data: PByte; Size: Integer): Int64;
    function ReplayAnswer(Kind: Integer; Time: Int64): Int64;
  protected
    procedure Execute; override;
  public
    // EE side: the time up to which it has taken outputs, work, ends of
    // channels and given answers.
    TakenUpTo: Int64;
    constructor Create(const Step: TFunc<TPS2AheadStep>);
    destructor Destroy; override;
    // EE thread: run ahead from Complete/Last; park (serving what the domain
    // waits for meanwhile).
    procedure Go(Complete, Last: Int64);
    procedure Pause(const Serve: TProc);
    function Parked: Boolean;
    function Complete: Int64;
    function Last: Int64;
    function Ended: Boolean;
    function RequestTime: Int64;
    // EE thread, parked: whether the thread failed, and with what ('' none;
    // cleared).
    function Failed: Boolean;
    function TakeFailure: string;
    // Domain thread.
    procedure Publish(Complete, Last: Int64);
    procedure Output(Time: Int64; Kind: Integer; Value: Cardinal);
    function Request(Kind: Integer; Time: Int64): Int64;
    // Domain thread: whether the session has kept as much as it may.
    function SessionFull: Boolean;
    // EE thread: the oldest output's time (High(Int64): none); outputs up
    // to UpTo; the pending request if due by UpTo.
    function OutputHead: Int64;
    procedure TakeOutputs(UpTo: Int64; Apply: TPS2DomainApply);
    function ServeRequest(UpTo: Int64; Serve: TPS2DomainServe): Boolean;
    // Domain thread (or a replay): a copy of Size bytes of memory at Source
    // for a device to read (Key: which; it goes on in its last copy where it
    // left it); ReadUsed: the bytes it took (Token: which read).
    function ReadCopy(Key: Integer; Time: Int64; Source: PByte; Size: Integer; out Token: Int64): PByte;
    procedure ReadUsed(Token: Int64; Used: Integer);
    // Domain thread (or a replay): how many of Count quadwords at Source the
    // device Key gets in its next copy (about twice what it took last, at
    // most the rest it kept; a replay: as the session read).
    function ReadLimit(Key: Integer; Source: PByte; Count: Integer): Integer;
    // Domain thread (or a replay): a decision from an EE-side register
    // (TPS2DomainRead.Check), kept to be checked at its time; the result to
    // go on with (a replay: the one made then).
    function PostCheck(Time: Int64; Source: PCardinal; Mask, Offset, Value: Cardinal; Decided: Boolean): Boolean;
    // EE thread: the time of the oldest read not checked (ConflictAt while a
    // conflict waits); the reads up to UpTo compared with memory as it is
    // now, up to the first that differs (its time: ConflictAt). A read the
    // device still has is compared whole (that covers what it takes): the
    // EE side decides on every read up to its time before it takes anything
    // from there, and reads made while it waits there find memory as it is.
    function ReadHead: Int64;
    procedure CheckReads(UpTo: Int64);
    function ConflictAt: Int64;
    // EE thread: from now on the thread's outputs and questions are dropped
    // (it is taken back past the EE's time).
    procedure Quieten;
    // EE thread, parked: going back, the outputs not taken are dropped; the
    // session's events come again (BeginReplay: its reads and answers in
    // order; EndReplay: those up to Applied all came again); the session
    // ends (what it kept is freed).
    procedure DropOutputs;
    procedure BeginReplay;
    procedure EndReplay(Applied: Int64);
    procedure EndSession;
  end;

implementation

constructor TPS2VU1Thread.Create(const Step: TFunc<TPS2AheadStep>);
begin
  FStep := Step;
  FWake := TEvent.Create(nil, False, False, '');
  FComplete := High(Int64);
  FCopyBlocks := TList<PByte>.Create;
  FCopyLarge := TList<PByte>.Create;
  FAnswers := TList<TPS2DomainAnswer>.Create;
  FCopyBlock := -1;
  FConflictAt := High(Int64);
  inherited Create(False);
end;

destructor TPS2VU1Thread.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  inherited;
  FWake.Free;
  for var B in FReadBlocks do
    FreeMem(B);
  if FCopyBlocks <> nil then
    for var P in FCopyBlocks do
      FreeMem(P);
  if FCopyLarge <> nil then
    for var P in FCopyLarge do
      FreeMem(P);
  FCopyBlocks.Free;
  FCopyLarge.Free;
  FAnswers.Free;
end;

procedure TPS2VU1Thread.Execute;
begin
  NameThreadForDebugging('PS2 VU1 ahead');
  while not Terminated do
  begin
    if TInterlocked.CompareExchange(FState, 2, 1) <> 1 then
    begin
      FWake.WaitFor(INFINITE);
      Continue;
    end;
    try
      while not Terminated and (TInterlocked.CompareExchange(FStop, 0, 0) = 0) do
      begin
        var R := FStep();
        if R <> asDone then
        begin
          if R = asEnd then
            TInterlocked.Exchange(FEnded, 1);
          Break;
        end;
      end;
    except
      on E: Exception do
      begin
        FFailure := E.ClassName + ': ' + E.Message;
        TInterlocked.Exchange(FEnded, 1);
      end;
    end;
    TInterlocked.Exchange(FState, 0);
  end;
end;

procedure TPS2VU1Thread.Go(Complete, Last: Int64);
begin
  TInterlocked.Exchange(FComplete, Complete);
  TInterlocked.Exchange(FLast, Last);
  TInterlocked.Exchange(FEnded, 0);
  TInterlocked.Exchange(FStop, 0);
  TInterlocked.Exchange(FState, 1);
  FWake.SetEvent;
end;

procedure TPS2VU1Thread.Pause(const Serve: TProc);
begin
  TInterlocked.Exchange(FStop, 1);
  var Spins := 0;
  while TInterlocked.CompareExchange(FState, 0, 0) <> 0 do
  begin
    if Assigned(Serve) then
      Serve();
    Inc(Spins);
    if Spins > SpinRounds then
      Sleep(0)
    else
      YieldProcessor;
  end;
end;

function TPS2VU1Thread.Parked: Boolean;
begin
  Result := LoadShared(FState) = 0;
end;

function TPS2VU1Thread.Complete: Int64;
begin
  Result := LoadShared(FComplete);
end;

function TPS2VU1Thread.Last: Int64;
begin
  Result := LoadShared(FLast);
end;

function TPS2VU1Thread.Ended: Boolean;
begin
  Result := TInterlocked.CompareExchange(FEnded, 0, 0) <> 0;
end;

function TPS2VU1Thread.Failed: Boolean;
begin
  Result := FFailure <> '';
end;

function TPS2VU1Thread.TakeFailure: string;
begin
  Result := FFailure;
  FFailure := '';
end;

function TPS2VU1Thread.RequestTime: Int64;
begin
  Result := High(Int64);
  if LoadShared(FRequestPending) <> 0 then
    Result := LoadShared(FRequestTime);
end;

procedure TPS2VU1Thread.Publish(Complete, Last: Int64);
begin
  StoreShared(FLast, Last);
  StoreShared(FComplete, Complete);
end;

procedure TPS2VU1Thread.Output(Time: Int64; Kind: Integer; Value: Cardinal);
begin
  if LoadShared(FQuiet) <> 0 then
    Exit;
  var Rounds := 0;
  while FOutPosted - LoadShared(FOutDone) >= OutSize do
  begin
    if LoadShared(FQuiet) <> 0 then
      Exit;
    WaitRound(Rounds);
  end;
  var O: ^TPS2DomainOutput := @FOut[FOutPosted and (OutSize - 1)];
  O.Time := Time;
  O.Kind := Kind;
  O.Value := Value;
  StoreShared(FOutPosted, FOutPosted + 1);
end;

function TPS2VU1Thread.Request(Kind: Integer; Time: Int64): Int64;
begin
  if FReplaying then
    Exit(ReplayAnswer(Kind, Time));
  FRequestKind := Kind;
  TInterlocked.Exchange(FRequestTime, Time);
  TInterlocked.Exchange(FRequestPending, 1);
  Result := 0;
  while TInterlocked.CompareExchange(FRequestPending, 0, 0) <> 0 do
  begin
    // (Taken back: the question is withdrawn, the answer does not matter.)
    if (LoadShared(FQuiet) <> 0) and (TInterlocked.CompareExchange(FRequestPending, 0, 1) = 1) then
      Exit;
    YieldProcessor;
  end;
  Result := TInterlocked.Read(FRequestResult);
end;

function TPS2VU1Thread.SessionFull: Boolean;
begin
  Result := (FReadPosted >= SessionReads) or (FSessionBytes >= SessionBytes);
end;

function TPS2VU1Thread.OutputHead: Int64;
begin
  Result := High(Int64);
  if FOutDone < LoadShared(FOutPosted) then
    Result := FOut[FOutDone and (OutSize - 1)].Time;
end;

procedure TPS2VU1Thread.TakeOutputs(UpTo: Int64; Apply: TPS2DomainApply);
begin
  var Posted := LoadShared(FOutPosted);
  while FOutDone < Posted do
  begin
    var O := FOut[FOutDone and (OutSize - 1)];
    if O.Time > UpTo then
      Break;
    Apply(O.Kind, O.Value);
    StoreShared(FOutDone, FOutDone + 1);
  end;
end;

function TPS2VU1Thread.ServeRequest(UpTo: Int64; Serve: TPS2DomainServe): Boolean;
begin
  Result := False;
  if LoadShared(FRequestPending) = 0 then
    Exit;
  var Time := LoadShared(FRequestTime);
  if Time > UpTo then
    Exit;
  var A: TPS2DomainAnswer;
  A.Time := Time;
  A.Kind := FRequestKind;
  A.Value := Serve(FRequestKind, Time);
  FAnswers.Add(A);
  TInterlocked.Exchange(FRequestResult, A.Value);
  TInterlocked.Exchange(FRequestPending, 0);
  Result := True;
end;

function TPS2VU1Thread.ReplayAnswer(Kind: Integer; Time: Int64): Int64;
begin
  if FReplayAnswer >= FAnswers.Count then
    raise EPS2Replay.Create('VU1 replay asks more than the session');
  var A := FAnswers[FReplayAnswer];
  if (A.Kind <> Kind) or (A.Time <> Time) then
    raise EPS2Replay.CreateFmt('VU1 replay asks %d at %d, the session %d at %d', [Kind, Time, A.Kind, A.Time]);
  Inc(FReplayAnswer);
  Result := A.Value;
end;

function TPS2VU1Thread.Read(Index: Int64): PPS2DomainRead;
begin
  Result := PPS2DomainRead(FReadBlocks[Index shr ReadShift] + (Index and (ReadBlock - 1)) * SizeOf(TPS2DomainRead));
end;

function TPS2VU1Thread.CopySpace(Need: Integer): PByte;
begin
  Inc(FSessionBytes, Need);
  if Need > CopyBlock then
  begin
    GetMem(Result, Need);
    FCopyLarge.Add(Result);
    Exit;
  end;
  if (FCopyBlock < 0) or (FCopyAt + Need > CopyBlock) then
  begin
    Inc(FCopyBlock);
    if FCopyBlock = FCopyBlocks.Count then
    begin
      GetMem(Result, CopyBlock);
      FCopyBlocks.Add(Result);
    end;
    FCopyAt := 0;
  end;
  Result := FCopyBlocks[FCopyBlock] + FCopyAt;
  Inc(FCopyAt, (Need + 15) and not 15);
end;

function TPS2VU1Thread.PostRead(Key: Integer; Time: Int64; Source, Data: PByte; Size: Integer): Int64;
begin
  Result := FReadPosted;
  var B := Result shr ReadShift;
  if B > High(FReadBlocks) then
    raise EPS2Replay.Create('VU1 session reads too much');
  if FReadBlocks[B] = nil then
    FReadBlocks[B] := AllocMem(ReadBlock * SizeOf(TPS2DomainRead));
  var R := Read(Result);
  R.Time := Time;
  R.Source := Source;
  R.Data := Data;
  R.Size := Size;
  R.Used := -1;
  R.Key := Key;
  R.Check := False;
  R.Ready := 0;
  StoreShared(FReadPosted, Result + 1);
end;

function TPS2VU1Thread.PostCheck(Time: Int64; Source: PCardinal; Mask, Offset, Value: Cardinal; Decided: Boolean): Boolean;
begin
  if FReplaying then
  begin
    if FReplayRead >= FReadPosted then
      raise EPS2Replay.Create('VU1 replay decides more than the session');
    var R := Read(FReplayRead);
    if not R.Check or (R.Source <> PByte(Source)) or (R.Value <> Value) or (R.Time <> Time) then
      raise EPS2Replay.Create('VU1 replay decides otherwise than the session');
    Inc(FReplayRead);
    Exit(R.Expect);
  end;
  var Index := FReadPosted;
  var B := Index shr ReadShift;
  if B > High(FReadBlocks) then
    raise EPS2Replay.Create('VU1 session reads too much');
  if FReadBlocks[B] = nil then
    FReadBlocks[B] := AllocMem(ReadBlock * SizeOf(TPS2DomainRead));
  var R := Read(Index);
  R.Time := Time;
  R.Source := PByte(Source);
  R.Data := nil;
  R.Size := 0;
  R.Used := 0;
  R.Key := 5;
  R.Check := True;
  R.Mask := Mask;
  R.Offset := Offset;
  R.Value := Value;
  R.Expect := Decided;
  R.Ready := 0;
  StoreShared(FReadPosted, Index + 1);
  // (Decided from the register once the check is posted: TPS2DomainRead.)
  Result := (((Source^ and Mask) or Offset) = Value);
  R.Expect := Result;
  StoreShared(R.Ready, 1);
end;

function TPS2VU1Thread.ReadCopy(Key: Integer; Time: Int64; Source: PByte; Size: Integer; out Token: Int64): PByte;
begin
  if FReplaying then
  begin
    // (The same reads come again, in their order, from their copies.)
    if FReplayRead >= FReadPosted then
      raise EPS2Replay.Create('VU1 replay reads more than the session');
    var R := Read(FReplayRead);
    if (R.Key <> Key) or (R.Source <> Source) or (R.Size <> Size) or (R.Time <> Time) then
      raise EPS2Replay.CreateFmt('VU1 replay reads %d bytes at %p (%d) at %d, the session %d at %p (%d) at %d', [Size, Pointer(Source), Key, Time, R.Size, Pointer(R.Source), R.Key, R.Time]);
    Token := FReplayRead;
    Inc(FReplayRead);
    Exit(R.Data);
  end;
  // The device goes on where it left its last copy: the rest of it, as long
  // as memory still holds the same (the copy is then as one taken now: a
  // read the EE side waits for finds memory as the EE has it).
  // (Posted first, then compared or copied: TPS2DomainRead.)
  var Tail := PPS2ReadTail(@FTails[Key]);
  if Tail.Kept then
  begin
    Tail.Kept := False;
    if (Tail.Source = Source) and (Size <= Tail.Size) then
    begin
      Token := PostRead(Key, Time, Source, Tail.Data, Size);
      if SameQuads(Source, Tail.Data, Size) then
      begin
        StoreShared(Read(Token).Ready, 1);
        Exit(Tail.Data);
      end;
      Result := CopySpace(Size + ReadSlack);
      Read(Token).Data := Result;
      Move(Source^, Result^, Size);
      StoreShared(Read(Token).Ready, 1);
      Exit;
    end;
  end;
  Result := CopySpace(Size + ReadSlack);
  Token := PostRead(Key, Time, Source, Result, Size);
  Move(Source^, Result^, Size);
  StoreShared(Read(Token).Ready, 1);
end;

procedure TPS2VU1Thread.ReadUsed(Token: Int64; Used: Integer);
begin
  var R := Read(Token);
  if FReplaying then
  begin
    if R.Used <> Used then
      raise EPS2Replay.CreateFmt('VU1 replay takes %d bytes, the session %d', [Used, R.Used]);
    Exit;
  end;
  var Tail := PPS2ReadTail(@FTails[R.Key]);
  if Used < R.Size then
  begin
    Tail.Kept := True;
    Tail.Source := R.Source + Used;
    Tail.Data := R.Data + Used;
    Tail.Size := R.Size - Used;
    Tail.Chunk := 2 * Used;
  end
  else if Tail.Chunk < 2 * R.Size then
    Tail.Chunk := 2 * R.Size;
  if Tail.Chunk > MaxChunk then
    Tail.Chunk := MaxChunk;
  StoreShared(R.Used, Used);
end;

function TPS2VU1Thread.ReadLimit(Key: Integer; Source: PByte; Count: Integer): Integer;
begin
  Result := Count;
  if FReplaying then
  begin
    // (A read that differs fails in ReadCopy.)
    if FReplayRead < FReadPosted then
    begin
      var R := Read(FReplayRead);
      if (R.Key = Key) and (R.Size div 16 < Count) then
        Result := R.Size div 16;
    end;
    Exit;
  end;
  var Tail := PPS2ReadTail(@FTails[Key]);
  var Bytes := Tail.Chunk;
  if Bytes < MinChunk then
    Bytes := MinChunk;
  if Tail.Kept and (Tail.Source = Source) and (Tail.Size < Bytes) then
    Bytes := Tail.Size;
  if Bytes div 16 < Count then
    Result := Bytes div 16;
  if Result < 1 then
    Result := 1;
end;

function TPS2VU1Thread.ReadHead: Int64;
begin
  if FConflictAt <> High(Int64) then
    Exit(FConflictAt);
  Result := High(Int64);
  if FReadChecked < LoadShared(FReadPosted) then
    Result := Read(FReadChecked).Time;
end;

procedure TPS2VU1Thread.CheckReads(UpTo: Int64);
begin
  if FConflictAt <> High(Int64) then
    Exit;
  var Posted := LoadShared(FReadPosted);
  while FReadChecked < Posted do
  begin
    var R := Read(FReadChecked);
    if R.Time > UpTo then
      Break;
    // (Its copy is being taken. A thread that parked without it failed
    // inside the read: nothing is taken from there on.)
    while LoadShared(R.Ready) = 0 do
    begin
      if (LoadShared(FState) = 0) and (LoadShared(R.Ready) = 0) then
      begin
        FConflictAt := R.Time;
        Exit;
      end;
      YieldProcessor;
    end;
    var Size := LoadShared(R.Used);
    if Size < 0 then
      Size := R.Size;
    var Same: Boolean;
    if R.Check then
      Same := (((PCardinal(R.Source)^ and R.Mask) or R.Offset) = R.Value) = R.Expect
    else
      Same := SameQuads(R.Source, R.Data, Size);
    if not Same then
    begin
      FConflictAt := R.Time;
      Exit;
    end;
    Inc(FReadChecked);
  end;
end;

function TPS2VU1Thread.ConflictAt: Int64;
begin
  Result := FConflictAt;
end;

procedure TPS2VU1Thread.Quieten;
begin
  StoreShared(FQuiet, 1);
end;

procedure TPS2VU1Thread.DropOutputs;
begin
  FOutDone := FOutPosted;
end;

procedure TPS2VU1Thread.BeginReplay;
begin
  FReplaying := True;
  FReplayRead := 0;
  FReplayAnswer := 0;
  FQuiet := 1;
end;

procedure TPS2VU1Thread.EndReplay(Applied: Int64);
begin
  FReplaying := False;
  if (FReplayRead < FReadPosted) and (Read(FReplayRead).Time <= Applied) then
    raise EPS2Replay.Create('VU1 replay reads less than the session');
  if (FReplayAnswer < FAnswers.Count) and (FAnswers[FReplayAnswer].Time <= Applied) then
    raise EPS2Replay.Create('VU1 replay asks less than the session');
end;

procedure TPS2VU1Thread.EndSession;
begin
  StoreShared(FReadPosted, 0);
  FReadChecked := 0;
  FConflictAt := High(Int64);
  for var K := 0 to High(FTails) do
    FTails[K].Kept := False;
  FCopyBlock := -1;
  FCopyAt := 0;
  FSessionBytes := 0;
  for var P in FCopyLarge do
    FreeMem(P);
  FCopyLarge.Clear;
  while FCopyBlocks.Count > KeptCopyBlocks do
  begin
    FreeMem(FCopyBlocks.Last);
    FCopyBlocks.Delete(FCopyBlocks.Count - 1);
  end;
  FAnswers.Clear;
  FReplaying := False;
  FOutDone := FOutPosted;
  FRequestPending := 0;
  StoreShared(FQuiet, 0);
end;

end.

