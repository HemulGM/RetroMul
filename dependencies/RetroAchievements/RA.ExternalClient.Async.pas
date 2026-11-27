unit RA.ExternalClient.Async;

interface

{$SCOPEDENUMS ON}
{$POINTERMATH ON}

uses
  System.Generics.Collections, System.SyncObjs, System.SysUtils,
  RA.ExternalClient.ABI, RA.Session;

type
  TRAExternalAsyncResult = record
    Code, HTTPStatus: Integer;
    MessageText, ServerCode: string;
    CandidateUnrecognized: Boolean;
    Entries: TArray<TRAClientLeaderboardEntry>;
    TotalEntries: Cardinal;
    UserIndex: Integer;
  end;

  TRAExternalRequestStart = reference to function(Client, Context: Pointer): Pointer;

  TRAExternalRequestCompleted = reference to procedure(const Data: TRAExternalAsyncResult);

  TRAExternalRequestKind = (Normal, GameLoad, MediaChange, Login, AccountQuery);

  TRAExternalRequestKinds = set of TRAExternalRequestKind;

  TRAExternalAsyncRequests = class
  private
    type
      TStage = (Queued, Running, Finished);

      TTicket = class(TInterfacedObject, IRAAsyncOperation)
      private
        FState: Integer;
      public
        procedure Cancel;
        function IsCanceled: Boolean;
        function TryDeliver: Boolean;
      end;

      TRequest = record
        Token, Handle: Pointer;
        KeepAlive, WaitForLoad: IRAAsyncOperation;
        Ticket: TTicket;
        Stage: TStage;
        LoadPhase: TRAGameLoadPhase;
        TryOtherHashes: Boolean;
        Kind: TRAExternalRequestKind;
        Start: TRAExternalRequestStart;
        Complete: TRAExternalRequestCompleted;
        Data: TRAExternalAsyncResult;
      end;
  private
    FLock: TCriticalSection;
    FRequests: TList<TRequest>;
    FNextToken: NativeUInt;
    FClosing: Boolean;
    FClient: Pointer;
    FAbort: TRAExternalAbortAsync;
    function Find(Token: Pointer): Integer;
    function PendingLoadIndex: Integer;
    procedure FinishDeferredMedia(const LoadTicket: IRAAsyncOperation; Success: Boolean);
    function TakeWork(out Request: TRequest): Boolean;
    function TakeCanceledHandle(Kinds: TRAExternalRequestKinds; out Request: TRequest): Boolean;
    procedure AbortCanceled(Kinds: TRAExternalRequestKinds);
  public
    constructor Create(Client: Pointer; Abort: TRAExternalAbortAsync);
    destructor Destroy; override;
    function Enqueue(const Start: TRAExternalRequestStart; const Complete: TRAExternalRequestCompleted; Phase: TRAGameLoadPhase = TRAGameLoadPhase.Idle; TryOtherHashes: Boolean = False; Kind: TRAExternalRequestKind = TRAExternalRequestKind.Normal): IRAAsyncOperation;
    // Running the provider and closing it are serialized by the session.
    procedure PumpProvider;
    procedure Deliver;
    procedure Finish(Token: Pointer; const Data: TRAExternalAsyncResult);
    function IsCanceled(Token: Pointer): Boolean;
    procedure Close;
    procedure CancelRequests(Kinds: TRAExternalRequestKinds);
    function HasPendingLogin: Boolean;
    function GetLoadPhase: TRAGameLoadPhase;
    function HasRunningLoad: Boolean;
  end;

function ExternalRequestStatus(const Data: TRAExternalAsyncResult): TRAQueryStatus;

function ExternalRequestResult(Code: Integer; const MessageText: string): TRAExternalAsyncResult;

procedure CopyExternalLeaderboardEntries(List: PRAExternalLeaderboardEntryList; var Data: TRAExternalAsyncResult);

implementation

uses
  RA.Errors, RA.ExternalClient.Events;

const
  TicketOpen = 0;
  TicketCanceled = 1;
  TicketDelivered = 2;

function ExternalRequestResult(Code: Integer; const MessageText: string): TRAExternalAsyncResult;
begin
  Result := Default(TRAExternalAsyncResult);
  Result.Code := Code;
  Result.MessageText := MessageText;
  Result.UserIndex := -1;
end;

function ExternalRequestStatus(const Data: TRAExternalAsyncResult): TRAQueryStatus;
begin
  Result := Default(TRAQueryStatus);
  Result.Success := Data.Code = RAExternalOK;
  Result.ResultCode := Data.Code;
  Result.HTTPStatus := Data.HTTPStatus;
  if Result.Success then
    Exit;
  case Data.Code of
    RAExternalInvalidState:
      Result.ServerCode := 'invalid_state';
    RAExternalLoginRequired:
      Result.ServerCode := 'login_required';
    RAExternalNoGameLoaded:
      Result.ServerCode := 'no_game_loaded';
    RAExternalHardcoreDisabled:
      Result.ServerCode := 'hardcore_disabled';
    RAExternalAborted:
      Result.ServerCode := 'aborted';
    RAExternalInvalidCredentials:
      Result.ServerCode := 'invalid_credentials';
    RAExternalExpiredToken:
      Result.ServerCode := 'expired_token';
    RAExternalNotFound:
      Result.ServerCode := 'not_found';
  else
    Result.ServerCode := IntToStr(Data.Code);
  end;
  if Data.ServerCode <> '' then
    Result.ServerCode := Data.ServerCode;
  Result.ErrorMessage := Data.MessageText;
  if Result.ErrorMessage = '' then
    Result.ErrorMessage := RAErrorMessage(Data.Code);
end;

procedure CopyExternalLeaderboardEntries(List: PRAExternalLeaderboardEntryList; var Data: TRAExternalAsyncResult);
begin
  if List = nil then
    Exit;
  Data.TotalEntries := List.TotalEntries;
  Data.UserIndex := List.UserIndex;
  SetLength(Data.Entries, CheckedExternalCount(List.Count, List.Entries));
  for var Index := 0 to High(Data.Entries) do
  begin
    var Source: PRAExternalLeaderboardEntry := @List.Entries[Index];
    Data.Entries[Index].UserName := ReadExternalText(Source.UserName);
    Data.Entries[Index].Display := ReadExternalText(@Source.Display[0], Length(Source.Display));
    Data.Entries[Index].Submitted := Source.Submitted;
    Data.Entries[Index].Rank := Source.Rank;
    Data.Entries[Index].Index := Source.Index;
  end;
end;

procedure TRAExternalAsyncRequests.TTicket.Cancel;
begin
  TInterlocked.CompareExchange(FState, TicketCanceled, TicketOpen);
end;

function TRAExternalAsyncRequests.TTicket.IsCanceled: Boolean;
begin
  Result := TInterlocked.CompareExchange(FState, TicketOpen, TicketOpen) = TicketCanceled;
end;

function TRAExternalAsyncRequests.TTicket.TryDeliver: Boolean;
begin
  Result := TInterlocked.CompareExchange(FState, TicketDelivered, TicketOpen) = TicketOpen;
end;

constructor TRAExternalAsyncRequests.Create(Client: Pointer; Abort: TRAExternalAbortAsync);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRequests := TList<TRequest>.Create;
  FClient := Client;
  FAbort := Abort;
end;

destructor TRAExternalAsyncRequests.Destroy;
begin
  FRequests.Free;
  FLock.Free;
  inherited;
end;

function TRAExternalAsyncRequests.Find(Token: Pointer): Integer;
begin
  for var Index := 0 to FRequests.Count - 1 do
    if FRequests[Index].Token = Token then
      Exit(Index);
  Result := -1;
end;

function TRAExternalAsyncRequests.Enqueue(const Start: TRAExternalRequestStart; const Complete: TRAExternalRequestCompleted; Phase: TRAGameLoadPhase; TryOtherHashes: Boolean; Kind: TRAExternalRequestKind): IRAAsyncOperation;
var
  Request: TRequest;
  LoadIndex: Integer;
begin
  Request := Default(TRequest);
  Request.Ticket := TTicket.Create;
  Request.KeepAlive := Request.Ticket;
  Request.LoadPhase := Phase;
  Request.TryOtherHashes := TryOtherHashes;
  if Phase = TRAGameLoadPhase.Idle then
    Request.Kind := Kind
  else
    Request.Kind := TRAExternalRequestKind.GameLoad;
  Request.Start := Start;
  Request.Complete := Complete;
  FLock.Acquire;
  try
    if FClosing then
    begin
      Request.Ticket.Cancel;
      Exit(Request.KeepAlive);
    end;
    Inc(FNextToken);
    Request.Token := Pointer(FNextToken);
    if Phase <> TRAGameLoadPhase.Idle then
    begin
      for var Pending in FRequests do
        if (Pending.LoadPhase <> TRAGameLoadPhase.Idle) or (Pending.Kind = TRAExternalRequestKind.MediaChange) then
          Pending.Ticket.Cancel;
    end
    else if Kind = TRAExternalRequestKind.MediaChange then
    begin
      LoadIndex := PendingLoadIndex;
      if LoadIndex >= 0 then
      begin
        // While game data is loading, only the last requested medium will be inserted.
        Request.WaitForLoad := FRequests[LoadIndex].KeepAlive;
        FinishDeferredMedia(Request.WaitForLoad, False);
      end;
    end;
    FRequests.Add(Request);
  finally
    FLock.Release;
  end;
  Result := Request.KeepAlive;
end;

function TRAExternalAsyncRequests.TakeWork(out Request: TRequest): Boolean;
begin
  FLock.Acquire;
  try
    if FClosing then
      Exit(False);
    for var Index := 0 to FRequests.Count - 1 do
    begin
      Request := FRequests[Index];
      if Request.Ticket.IsCanceled then
      begin
        if Request.LoadPhase <> TRAGameLoadPhase.Idle then
          FinishDeferredMedia(Request.KeepAlive, False);
        if (Request.Stage = TStage.Running) and not Assigned(FAbort) then
          Continue;
        FRequests.Delete(Index);
        Exit(True);
      end;
      if (Request.Stage = TStage.Queued) and (Request.WaitForLoad = nil) then
      begin
        Request.Stage := TStage.Running;
        FRequests[Index] := Request;
        Exit(True);
      end;
    end;
  finally
    FLock.Release;
  end;
  Result := False;
end;

procedure TRAExternalAsyncRequests.PumpProvider;
var
  Request, Active: TRequest;
  Handle: Pointer;
  Index: Integer;
begin
  while TakeWork(Request) do
  begin
    // A finished request has no usable C handle, even if the begin function returned one.
    if Request.Ticket.IsCanceled and (Request.Stage <> TStage.Running) then
      Continue;
    if Request.Ticket.IsCanceled and (Request.Handle <> nil) then
    begin
      FAbort(Request.Handle);
      Continue;
    end;
    if Request.Ticket.IsCanceled then
    begin
      Finish(Request.Token, ExternalRequestResult(RAExternalAborted, 'Canceled'));
      Continue;
    end;

    try
      Handle := Request.Start(FClient, Request.Token);
      if Handle = nil then
        Finish(Request.Token, ExternalRequestResult(RAExternalInvalidState, 'External request returned no handle or result'))
      else
      begin
        FLock.Acquire;
        try
          Index := Find(Request.Token);
          if Index >= 0 then
          begin
            Active := FRequests[Index];
            if Active.Stage = TStage.Running then
            begin
              Active.Handle := Handle;
              FRequests[Index] := Active;
            end;
          end;
        finally
          FLock.Release;
        end;
      end;
    except
      on Error: Exception do
        Finish(Request.Token, ExternalRequestResult(RAExternalInvalidState, Error.Message));
    end;
    // A provider can reenter the session and cancel before returning its handle.
    if Request.Ticket.IsCanceled then
      AbortCanceled([Request.Kind]);
    Break;
  end;
end;

procedure TRAExternalAsyncRequests.Finish(Token: Pointer; const Data: TRAExternalAsyncResult);
var
  Index: Integer;
  Request: TRequest;
begin
  FLock.Acquire;
  try
    Index := Find(Token);
    if Index < 0 then
      Exit;
    Request := FRequests[Index];
    if Request.Stage <> TStage.Running then
      Exit;
    Request.Stage := TStage.Finished;
    Request.Handle := nil;
    if not Request.Ticket.IsCanceled then
      Request.Data := Data;
    FRequests[Index] := Request;
  finally
    FLock.Release;
  end;
end;

function TRAExternalAsyncRequests.IsCanceled(Token: Pointer): Boolean;
var
  Index: Integer;
begin
  FLock.Acquire;
  try
    Index := Find(Token);
    Result := FClosing or (Index < 0) or FRequests[Index].Ticket.IsCanceled;
  finally
    FLock.Release;
  end;
end;

procedure TRAExternalAsyncRequests.Deliver;
var
  Request: TRequest;
  Index: Integer;
  Notify: Boolean;
begin
  repeat
    FLock.Acquire;
    try
      if FClosing then
        Exit;
      Index := 0;
      while (Index < FRequests.Count) and (FRequests[Index].Stage <> TStage.Finished) do
        Inc(Index);
      if Index = FRequests.Count then
        Exit;
      Request := FRequests[Index];
      if Request.TryOtherHashes and Request.Data.CandidateUnrecognized and not Request.Ticket.IsCanceled then
      begin
        // The same Delphi ticket spans the search, but each attempt needs a distinct C callback token.
        Inc(FNextToken);
        Request.Token := Pointer(FNextToken);
        Request.Stage := TStage.Queued;
        Request.Data := Default(TRAExternalAsyncResult);
        FRequests[Index] := Request;
        Continue;
      end;
      FRequests.Delete(Index);
      Notify := Request.Ticket.TryDeliver;
      if Request.LoadPhase <> TRAGameLoadPhase.Idle then
        FinishDeferredMedia(Request.KeepAlive, Notify and (Request.Data.Code = RAExternalOK));
    finally
      FLock.Release;
    end;
    if Notify and Assigned(Request.Complete) then
      Request.Complete(Request.Data);
  until False;
end;

function TRAExternalAsyncRequests.TakeCanceledHandle(Kinds: TRAExternalRequestKinds; out Request: TRequest): Boolean;
begin
  FLock.Acquire;
  try
    for var Index := 0 to FRequests.Count - 1 do
    begin
      Request := FRequests[Index];
      if (Request.Kind in Kinds) and Request.Ticket.IsCanceled and
        (Request.Stage = TStage.Running) and (Request.Handle <> nil) then
      begin
        if Request.LoadPhase <> TRAGameLoadPhase.Idle then
          FinishDeferredMedia(Request.KeepAlive, False);
        FRequests.Delete(Index);
        Exit(True);
      end;
    end;
    Request := Default(TRequest);
    Result := False;
  finally
    FLock.Release;
  end;
end;

procedure TRAExternalAsyncRequests.AbortCanceled(Kinds: TRAExternalRequestKinds);
var
  Request: TRequest;
begin
  if not Assigned(FAbort) then
    Exit;
  // An abort can complete another request inline. Select each handle just before using it.
  while TakeCanceledHandle(Kinds, Request) do
    FAbort(Request.Handle);
end;

procedure TRAExternalAsyncRequests.Close;
begin
  FLock.Acquire;
  try
    if FClosing then
      Exit;
    FClosing := True;
    for var Request in FRequests do
      Request.Ticket.Cancel;
  finally
    FLock.Release;
  end;
  AbortCanceled([Low(TRAExternalRequestKind)..High(TRAExternalRequestKind)]);
end;

procedure TRAExternalAsyncRequests.CancelRequests(Kinds: TRAExternalRequestKinds);
var
  Request: TRequest;
begin
  FLock.Acquire;
  try
    for var Index := FRequests.Count - 1 downto 0 do
    begin
      Request := FRequests[Index];
      if not (Request.Kind in Kinds) then
        Continue;

      Request.Ticket.Cancel;
      // A running request without a handle may still be inside the provider's begin function.
      if Request.Stage <> TStage.Running then
        FRequests.Delete(Index);
    end;
  finally
    FLock.Release;
  end;
  AbortCanceled(Kinds);
end;

function TRAExternalAsyncRequests.HasPendingLogin: Boolean;
begin
  FLock.Acquire;
  try
    for var Request in FRequests do
      if (Request.Kind = TRAExternalRequestKind.Login) and not Request.Ticket.IsCanceled then
        Exit(True);
  finally
    FLock.Release;
  end;
  Result := False;
end;

procedure TRAExternalAsyncRequests.FinishDeferredMedia(const LoadTicket: IRAAsyncOperation; Success: Boolean);
var
  Request: TRequest;
begin
  for var Index := 0 to FRequests.Count - 1 do
  begin
    Request := FRequests[Index];
    if Request.WaitForLoad <> LoadTicket then
      Continue;
    Request.WaitForLoad := nil;
    if not Success then
      Request.Ticket.Cancel;
    FRequests[Index] := Request;
  end;
end;

function TRAExternalAsyncRequests.PendingLoadIndex: Integer;
begin
  for var Index := FRequests.Count - 1 downto 0 do
    if not FRequests[Index].Ticket.IsCanceled and (FRequests[Index].LoadPhase <> TRAGameLoadPhase.Idle) then
      Exit(Index);
  Result := -1;
end;

function TRAExternalAsyncRequests.GetLoadPhase: TRAGameLoadPhase;
var
  Index: Integer;
begin
  FLock.Acquire;
  try
    Index := PendingLoadIndex;
    if Index >= 0 then
      Result := FRequests[Index].LoadPhase
    else
      Result := TRAGameLoadPhase.Idle;
  finally
    FLock.Release;
  end;
end;

function TRAExternalAsyncRequests.HasRunningLoad: Boolean;
var
  Index: Integer;
begin
  FLock.Acquire;
  try
    Index := PendingLoadIndex;
    Result := (Index >= 0) and (FRequests[Index].Stage = TStage.Running);
  finally
    FLock.Release;
  end;
end;

end.

