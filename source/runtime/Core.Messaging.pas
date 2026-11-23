unit Core.Messaging;

interface

uses
  Core.Messaging.Types;

function CreateUnavailableMessagingProvider: IMessagingProvider;

implementation

type
  TUnavailableMessagingProvider = class(TInterfacedObject, IMessagingProvider)
    function Info: TMessagingInfo;
    function Open(const Address: TMessageAddress; Mode: Integer; out Channel: IMessagingChannel): TMessagingError;
  end;

function TUnavailableMessagingProvider.Info: TMessagingInfo;
begin
  Result := Default(TMessagingInfo);
  Result.State := TMessagingState.Unavailable;
end;

function TUnavailableMessagingProvider.Open(const Address: TMessageAddress; Mode: Integer; out Channel: IMessagingChannel): TMessagingError;
begin
  Channel := nil;
  Result := TMessagingError.Unavailable;
end;

function CreateUnavailableMessagingProvider: IMessagingProvider;
begin
  Result := TUnavailableMessagingProvider.Create;
end;

end.

