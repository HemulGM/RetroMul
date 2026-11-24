unit PS2.GS.Scanout;
interface

type
  TPS2PageQueueTimes = array[0..511] of Int64;
  PPS2PageQueueTimes = ^TPS2PageQueueTimes;
  TRGBDamage = array[0..15] of Cardinal;
  PRGBDamage = ^TRGBDamage;

var
  NextGSQueueId: Int64;

const
  TrackDisplayRGB = True;

// A display read may reuse scaled pixels only for pages owned by its queue
// through the required serial. The pointers belong to the active read scope.
threadvar
  GSWriterQueueId, GSReaderQueueId: Int64;
  GSCompletedPrefix: PInt64;
  GSDisplayPageTimes: PPS2PageQueueTimes;
  ChannelDamage: PRGBDamage;
  ChannelFrom, ChannelTo: Int64;

implementation

end.
