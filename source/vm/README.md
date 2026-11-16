# JVM and initial Java ME runtime

The JVM is an independent Delphi implementation. `jvm/JVM.*` contains the class
reader, class/member linker, bytecode structure/type-flow checks, interpreter,
managed heap, thread scheduler, monitors and embedding API.
`java/Java.Bootstrap` supplies an initial shared Java library. Neither layer
depends on RetroMul, FMX, storage, or the Java ME frontend.

`source/cores/j2me` implements JAR/JAD suites, the MIDlet/Canvas host and initial
LCDUI screens.
`source/platforms/j2me` connects that host to RetroMul through `IEmulationCore`.
Each VM owns its classes, static fields, heap, intern table, and call frames.
The borrowed `TJVMHost` must outlive its VM; a borrowed J2ME suite must outlive
the J2ME runtime. Class definitions transfer ownership to the VM on success.
Hosts supply both epoch time and a monotonic millisecond clock for waits/sleep.
`BeginCall` schedules the main embedding callback. `CreateExecutionContext` and
`BeginContextCall` provide additional persistent embedding threads with separate
state/result/error queries. `Execute` advances all runnable threads; its return
state describes the main callback, not the liveness of every Java thread.
Contexts keep their Java thread identity between callbacks and are owned until
VM destruction. Their last result and uncaught exception remain GC roots until
the next call. A context's guest exception stays local; `RequestStop` stops all
threads and running contexts.

Native embedders may retain a Java reference in NativeContinuation while polling
an external operation. HasNativeContinuation detects when that call has unwound,
so the embedder can cancel resources promptly rather than waiting for heap GC.
SleepCurrent's optional RetryInterrupted mode resumes the native handler with
an interrupt visible to ClearInterrupted; it can release the operation and build
an I/O exception with the actual transfer count. Ordinary sleeps keep their
existing automatic InterruptedException behavior.

The reusable Bluetooth contract is in source/runtime/Core.Bluetooth.Types.pas,
with an explicit unavailable provider in Core.Bluetooth.pas and bounded virtual
RFCOMM/L2CAP channels in Core.Bluetooth.Channel.pas. These RTL-only modules have
no JVM, Java, FMX or phone-profile dependency. Device/service discovery and
connection/listener operations are cancellable and polled by their consumer.
RFCOMM partial writes and L2CAP packet boundaries remain distinct; actual link
security is separate from requested security. BLE/GATT has an optional interface
instead of being modelled as a byte stream. Address/UUID helpers use canonical
Bluetooth byte order and the standard base UUID.
Core.Bluetooth.Service supplies shared SDP service binding, record encoding,
decoding, UUID matching and attribute snapshots; both the Java translator and
native platform backend reuse it.

J2ME runtime accepts an optional IBluetoothProvider. The emulation adapter exposes
IEmulationBluetooth; bind a provider while stopped, then Start/Reset retains it
for that runtime. The frontend adapter creates the platform provider by default:
Windows uses Core.Platforms.Bluetooth.Windows; other platforms report Unavailable.
The standalone runtime with no provider, and an explicit adapter reset to nil,
also report Unavailable, with failed operations rather than successful empty
discovery. The provider itself reports hardware/permission/power changes.
J2ME.Bluetooth translates device/service discovery and delegates
`btspp://` and `btl2cap://` GCF calls to J2ME.Bluetooth.Transport. Java clients,
notifiers, RFCOMM Input/Output/Data streams and L2CAP packets use the same provider.
Blocking transport calls yield the guest scheduler. Partial writes retain their progress;
interrupts cancel outstanding work and report bytesTransferred. Stream handles
remain usable after their parent connection handle closes, until the streams
also close. L2CAP send/receive truncate at the appropriate MTU/buffer boundary,
and ready preserves a prefetched packet, including an empty packet.

The optional IBluetoothServiceRegistration prepares a bound listener without
advertising it, then publishes/updates its SDP record on acceptAndOpen. A local
updateRecord before first accept validates the record without publishing it.
Required class/protocol attributes, bound channel/PSM, UUID canonicalization and
aggregate SDP limits are checked. Close unregisters the listener. The optional
IBluetoothLinkControl negotiates live authentication, authorization or encryption;
Java queries use achieved channel security, and wait for operation completion.
Providers must reject unsupported role/security requests rather than silently
claiming success. Channel endpoints and required negotiated security/MTUs are
validated before Java receives the connection. Name lookup, remote record
population and discoverability waits also cancel their pending operation on
interruption and construct the corresponding Java exception.

DiscoveryAgent.selectService now searches paired known devices, the inquiry
cache and other provider-known devices before issuing a GIAC inquiry. Device
addresses are deduplicated; only a UUID in the actual ServiceClassIDList matches.
The method returns a validated RFCOMM/L2CAP URL or null when no usable service is
found. Security/master parameters describe the later connection's requirements;
selection itself does not connect or prove achieved security. Higher protocol
stacks such as OBEX are skipped instead of returning an incorrect raw-stream URL.
Each invocation owns a native continuation, yields the guest scheduler, retains
its state through GC and cancels outstanding work on interruption, unwind or
shutdown. Selection and public searches share the four-SDP-query limit, and
selection inquiry also excludes a simultaneous public inquiry. Selection does
not deliver callbacks to application DiscoveryListeners. Candidate/result counts
and aggregate SDP bytes are bounded; unavailable providers, failed inquiries,
malformed records and inconsistent endpoints produce BluetoothStateException.
Both selection and listener-based discovery observe operation state before
draining results, so a final result published between an empty read and native
completion is consumed on a later poll instead of being discarded.

The Windows backend uses the standard Winapi.Bluetooth/Winsock2 RTL declarations,
with no third-party binary. It implements cached radio/device metadata, GIAC
inquiry, raw SDP service search, RFCOMM connect/listen/accept and deferred SDP
publication. Jobs are bounded and cancellable; workers never invoke guest code.
Cancellation is immediate to the consumer, although a blocking native inquiry
start must return before its worker can release the native lookup. Overlapped
WSASend/WSARecv use owned buffers and events; public channel calls poll instead of
blocking. Accepted writes retain snapshots, and close attempts to drain them for
up to two seconds. Discoverability changes retain the prior value and restore it
on provider teardown if it still matches the value set by this provider.

Windows advertises RFCOMM, device discovery and service discovery only. Raw
Classic L2CAP is unsupported by this user-mode backend. Publishing an unchanged
record succeeds; changing an already published record returns Unsupported and
preserves the previous registration. Initial authentication/encryption use native
socket options, and reported security is the enforced known minimum. Master-role
and application authorization requests, live security changes, LIAC and a custom
pairing UI remain unsupported. Other OS backends, OBEX and physical
peer interoperability remain pending. Scripted channel tests and Winsock TCP
loopback tests do not prove over-air RFCOMM connectivity.

The reusable messaging contract lives in `source/runtime/Core.Messaging.Types`.
`IMessagingProvider` opens nonblocking SMS/CBS channels; `IEmulationMessaging`
binds a provider to a stopped core and retains it across Reset. These RTL-only
modules have no dependency on Java, FMX or a device profile. The default provider
reports Unavailable. `Core.Messaging.Virtual` supplies an in-process network
with phone/application-port routing, offline queues, end-user inboxes and CBS
broadcast. Accepted messages own snapshots. Queues have independent limits for
messages, addresses, SMS segments and aggregate payload bytes (8 MiB by default).
The default virtual SMS limit is255 segments; a provider may advertise a lower
limit. This transport does not send messages through a carrier.

`J2ME.Messaging` translates JSR-120 Message, TextMessage, BinaryMessage,
MessageConnection and MessageListener through that provider. GCF understands
`sms://` and `cbs://`; blocking guest operations yield the JVM scheduler and
support close/interrupt cancellation with InterruptedIOException. Notifications
use a persistent guest thread, cancel stale listener generations and remain
available while the MIDlet self-pauses. Host pause suspends their delivery.
BinaryMessage intentionally returns the same guest byte array from getPayloadData
as supplied to setPayloadData, while an accepted send takes a transport snapshot.
Outgoing/CBS timestamps are null; received SMS dates are independent snapshots.
Factories and segment counting remain available after close. GSM default and
extension characters, UCS-2 and binary budgets include the WMA16-bit port and
concatenation headers. Counting is independent of the provider's segment cap;
more than255 protocol parts returns zero. Native carrier backends, PushRegistry
activation and MMS/JSR-205 remain pending.

## Implemented foundation

- Class file versions 45 through 51, bounded attribute/constant parsing,
  modified UTF-8, descriptors, exception tables, and preserved StackMap data.
  Accepting a version is not a claim of complete Java SE compatibility.
- Bytecode instruction boundaries, branch targets, local indices, switch
  tables, and exception handler boundaries are checked before execution.
- `JVM.Verifier` checks every bytecode method before a class initializes or runs:
  operand/local types, category-2 slots, merges, arrays, calls/returns, constructor
  aliases and uninitialized-this, exception edges and context-sensitive legacy
  jsr/ret. It consumes CLDC StackMap and Java StackMapTable frames, checks map
  types/offsets/limits and required modern branch frames, and verifies declared
  unreachable map blocks. Stack-map formats are selected by class-file version.
  Constant pool references, descriptors, duplicate members, ConstantValue types
  and declaration flags are checked by the class reader. Verification state and
  failures are cached per class. Guest code can catch Java VerifyError; malformed
  classes loaded during execution produce ClassFormatError.
- `JVM.Linker` checks superclass/interface kind and visibility, circularity,
  final superclass/method constraints, and class/member access in one defining
  loader per VM. Field resolution searches declared fields, superinterfaces and
  then the superclass. Calls resolve a symbolic declaration before virtual or
  interface method selection; constructors are not inherited, package/private
  shadows do not become overrides, and invokespecial follows ACC_SUPER.
  The verifier checks cross-package protected receivers. Runtime resolution
  failures become catchable Java linkage errors. Array classes use their
  component's access rules; array clone is public and returns a distinct array.
  Writes narrow byte/short/char/boolean fields. Final-field writes always require
  the declaring class. Historical class files permit helper methods in that class
  to assign final fields; initializer-only enforcement starts at version53,
  matching OpenJDK's versioned compatibility rule. The normal loader's existing
  maximum remains51; tests explicitly preload52/53 fixtures through DefineClass
  to verify the boundary without advertising support for newer Java platforms.
- Integer/long/float/double operations, conversions, calls, fields, class
  initialization, arrays, type checks, exceptions and stack manipulation.
  Legacy `jsr`/`ret` and multidimensional arrays have initial implementations.
- Resumable instruction budgets and a stop request, explicit heap roots and
  mark/sweep collection at instruction boundaries. Dynamic strings are not
  automatically interned. Hosts must root references they retain between calls.
  Native handlers can request YieldToHost after a bounded work block; Execute
  resumes the guest caller on its next invocation. IsObjectAlive allows native
  resource cleanup after GC without permanently rooting every native object.
  InvokeGuestResult/TakeGuestResult let native methods suspend for ordinary guest
  calls with return values. NativeContinuation retains GC-traced per-frame state;
  RetryNative resumes bounded native work on a later Execute call. Callback
  exceptions unwind normally and discard their continuation with the frame.
  ResolveVirtualMethod selects a native-to-guest callback using the existing
  declaration/override rules, including array receivers and private shadows.
  Its declaration must belong to the same VM.
- Cooperative Java threads with independent frames, bounded priority-weighted
  quanta, Runnable targets and Thread subclasses, start/join/sleep/yield,
  interrupt flags, names and priorities. `wait` releases all recursive monitor
  entries and restores their depth before returning/throwing. Notify does not
  release the caller's monitor. Synchronized methods and blocks use the same
  reentrant monitors, including Class mirrors for static synchronized methods.
- Initialization ownership blocks competing threads. Superclasses initialize
  before subclass bodies; failures wake waiters, wrap non-Error throwables in
  ExceptionInInitializerError and produce NoClassDefFoundError on later access.
  Class literals/getClass and a small Class query API use shared mirrors.
  Uncaught child exceptions terminate that child and are available through
  `TakeThreadError`; an uncaught foreground exception faults the VM. Embedding
  error diagnostics include a bounded throw-site method/bytecode-PC trace;
  array access errors also report the index and array length. This diagnostic
  remains a separate throw-site diagnostic. Guest Throwable constructors now
  retain a snapshot of up to 64 frames; printStackTrace prints its virtual
  toString header and the construction snapshot through System.err. Runtime
  exceptions capture their origin, and rethrowing preserves the saved snapshot.
  CLDC null/empty messages and virtual getMessage are distinguished.
- Shared initial Object/String/StringBuffer/StringBuilder, exception hierarchy,
  Object/array clone, System.arraycopy/time/GC and floating-point
  bit conversions. Cloneable and Serializable marker types are available.
- `Java.Math` provides the CLDC 1.1 Math API: E/PI, all int/long/float/double
  abs/min/max overloads, sin/cos/tan/sqrt, ceil/floor and angular conversions.
  Integer minima preserve Java overflow behavior; floating predicates/rounding
  handle NaNs, infinities, both zero signs and huge integral values explicitly.
  A fixed 1664-bit 2/pi product reduces finite double angles before calling the
  RTL sine/cosine kernels on a small interval. Tangent uses a compensated
  32-term series and reciprocal correction, retaining the reduced-angle tail.
  The constants/coefficients are generated from mathematical recurrences with
  standard Python Decimal/Fraction, without copied third-party implementations.
  Angular subnormal results use an exact integer mantissa product and one final
  ties-to-even rounding, avoiding x87 double rounding at underflow.
  JDK comparisons currently cover 177809 cases; observed trigonometric distance
  is at most one ULP in that grid. This is bounded evidence, not an exhaustive
  proof or a Java SE StrictMath implementation.
- Execute borrows a Java floating environment with nearest rounding and masked
  arithmetic exceptions, restoring the embedding thread's settings in finally.
  Windows x86 additionally selects 53-bit precision; x86/x64 Windows saves raw
  x87/MXCSR controls and disables DAZ/FTZ. ARM uses the public RTL FPSCR controls
  to disable flush-to-zero and restore the supported saved state. Other targets
  use RTL rounding/exception-mask APIs; direct foreign DAZ/FTZ changes there
  remain outside the current tests. Windows checks cover non-nearest rounding,
  single x87 precision, DAZ/FTZ, subnormal operations and exceptional completion.
- The VM exposes a pure HasRunnableWork scheduler query. J2ME NeedsExecution
  combines it with lifecycle suspension and queued host/UI work. The worker and
  probe sleep only while no such work is ready. Busy guest code and bounded
  cooperative native work continue between host polls without an unconditional
  sleep after every instruction block; sleeping/waiting threads and paused
  applications still permit host backoff. The query does not advance clocks or
  execute instructions. This changes host scheduling, not Java monitor rules or
  the instruction quantum.
- `Java.Diagnostics` supplies initial CLDC PrintStream and per-VM System.out/err.
  Integer/long, boolean, char/array, string and object printing use the shared
  Java conversions and the host's default encoding. The stream retains a split
  surrogate and emits the UTF-16 BOM once. LF is the default line.separator;
  hosts can supply another separator through GetProperty. IOException in the
  output/flush/close path sets the stream error flag for checkError; other guest
  exceptions propagate. Nested streams, protected setError, serialized println
  and reentrant close use ordinary guest calls and monitors. Closing releases
  the underlying stream, including on callback errors. Float/double overloads
  use the same native Java floating-text converter as builders and numeric wrappers.
  Standard output/error bytes are retained in a bounded 64 KiB ring per VM.
  TakeOutput returns ordered channel-tagged chunks up to 4096 bytes; a host must
  decode each channel incrementally because chunk boundaries can split a character.
  OutputDropped counts evicted bytes. QueueOutput/TakeOutput follow the VM's
  existing single-executor embedding contract and are not cross-thread queues.
- TraceExceptionDiagnostics is an opt-in per-VM embedding diagnostic. It records
  throw sites before unwinding, including exceptions caught by guest code.
  A FIFO retains the latest 64 entries of at most 4096 UTF-16 characters each,
  with thread/instruction information, class, bounded message and stack trace.
  ExceptionDiagnosticsDropped counts evicted entries. TakeExceptionDiagnostic
  drains it without advancing time/instructions or retaining guest object roots.
  Tracing defaults off and does not change guest catch/Throwable behavior.
- Object.toString uses the binary class name and lowercase unsigned hash text,
  calling the guest's virtual hashCode through a resumable callback. String.valueOf
  supports int/long, float/double, boolean, char, char arrays/slices and objects; object conversion
  preserves virtual toString, null results, GC/yield and callback exceptions.
  StringBuffer/StringBuilder append(Object) use the same conversion path.
  StringBuffer methods keep its monitor across callbacks, and String(StringBuffer)
  obtains a synchronized immutable snapshot. Floating-point valueOf overloads use
  the shared integer-based converter described below.
- `Java.Builders` implements mutable UTF-16 buffers with reserved character
  storage and a separate logical length. StringBuffer/StringBuilder support
  charAt/setCharAt/getChars, setLength with zero filling, capacity/ensureCapacity,
  char-array append/insert (including slices), scalar/string/object insert,
  deletion and reverse. Returned strings are immutable snapshots; object
  conversions can yield, throw, GC or reenter the same buffer. StringBuffer
  retains its monitor across these callbacks. Growth checks the VM character
  capacity limit before changing contents. CLDC StringBuffer reverse operates on
  code units, including surrogates; the StringBuilder extension preserves pairs
  as Java SE specifies. Exact float/double decimal conversion remains pending.
- `Java.Reflection` supplies the CLDC Class.forName/newInstance/toString APIs.
  Binary names and array descriptors resolve to stable class mirrors; arrays do
  not initialize their component class. Ordinary class initialization uses the
  VM's resumable initialization frames, including contention and failure state.
  newInstance checks class/constructor accessibility, requires a no-argument
  constructor, roots the allocated receiver while the constructor yields and
  propagates constructor exceptions directly. Missing requested classes produce
  ClassNotFoundException; missing dependencies, malformed files and verification
  failures retain their corresponding linkage errors. IllegalAccessException
  and InstantiationException are available. General java.lang.reflect is absent.
- `Java.Environment` implements the CLDC Runtime singleton, gc/freeMemory/
  totalMemory/exit and System.exit. Each VM estimates its own guest object,
  tagged-array-slot, UTF-16 string/buffer, trace and field storage. The logical
  capacity starts at 16 MiB and expands in 1 MiB increments when measured usage
  exceeds it; GC reduces measured usage and retains the expanded capacity.
  This is an interpreter heap estimate, not host-process memory or a hard byte
  budget. Class metadata, execution stacks, allocator slack and native media/
  network services are excluded; object/array quotas remain independent limits.
  Memory queries scan the current heap on its executor. Runtime identity and
  capacity are isolated between VMs. Guest exit uses an internal control signal,
  stops all threads/contexts without returning through guest catch/finally,
  retains a signed exit status, and marks a J2ME application Destroyed. It does
  not terminate the embedding process. Exited VMs reject new calls/contexts.
- Shared String char-array construction/copy, forward/reverse searches, prefix/
  suffix and region comparisons, char replacement, trim and simple character
  case conversion. Repeated-prefix string searches use linear KMP. Locale-aware
  multi-character case conversion is not implemented. System.getProperty uses
  the embedding host; the J2ME host reports its experimental device properties.
- `Java.Characters` implements the CLDC 1.1 Character wrapper, four constants,
  charValue, equals/hashCode/toString, isLowerCase/isUpperCase/isDigit,
  toLowerCase/toUpperCase and digit. `Java.Unicode` supplies fixed tables for
  all 65536 BMP code units, including unchanged surrogate/unassigned values.
  Its 891 compressed ranges derive from the official Unicode 3.0 database;
  Unicode-LICENSE.txt accompanies the generated data. No runtime database,
  host OS Unicode tables or native third-party binary is needed.
  The explicit CLDC Latin-1 lowercase list excludes U+00AA/U+00B5/U+00BA;
  the remaining BMP blocks use Unicode 3.0 Ll/Lu/Nd properties and simple case
  mappings. digit accepts decimal digits and ASCII/fullwidth Latin letters for
  radices 2..36; other radices or unavailable digits return -1.
  String case conversion/comparison and Integer/Long/Byte/Short parsing share these
  fixed mappings. Characters added after Unicode 3.0 no longer acquire new
  behavior from the installed RTL/OS. CLDC ignore-case comparison checks the
  original characters' independent upper OR lower mappings, including its
  Turkish-I distinction from modern Java SE. Supplementary-code-point/int
  overloads and the wider Java SE Character API are not provided.
- `Java.Booleans` supplies the CLDC Boolean wrapper: boolean constructor,
  booleanValue, equals/hashCode/toString and final TRUE/FALSE objects. Verified
  guest class initialization allocates the two constants per VM, with normal
  initialization ownership and GC roots. New constructors remain distinct from
  those constants. String constructors and wider Java SE Boolean helpers are
  not supplied.
- `Java.Charsets` provides native UTF-8, ISO-8859-1, US-ASCII, UTF-16, UTF-16BE
  and UTF-16LE conversion with common explicit aliases. String byte-array
  constructors/getBytes and ByteArrayOutputStream.toString use the shared layer.
  NUL, supplementary pairs, malformed sequence replacement and UTF-16 BOM rules
  are handled explicitly, independently of the host OS code page. Unknown
  encodings raise UnsupportedEncodingException. `TJavaHost.DefaultEncoding`
  defaults to UTF-8 and can be overridden per embedding host; the J2ME encoding
  property reports that same choice. Encoded output obeys VM array limits.
- `Java.Readers` provides CLDC Reader and InputStreamReader, with the two
  input-stream constructors, scalar/array reads, skip, ready, close and unsupported
  mark/reset defaults. The shared incremental charset decoder preserves partial
  sequences and BOM state across input reads, flushes malformed tails at EOF and
  retains a pending low surrogate when the caller has one free char slot.
  Reader.skip uses the protected lock; InputStreamReader serializes reads,
  readiness and close across ordinary virtual InputStream callbacks, including
  yielding, guest GC and exceptions. ready may prefetch advertised available
  bytes and conservatively returns false for an incomplete character. Closing
  releases the stream and byte-buffer heap references, including on close errors.
  This is an initial implementation of the
  [CLDC 1.1 Reader contract](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/io/InputStreamReader.html),
  not a Java SE character-stream library.
- `Java.Writers` provides CLDC Writer and OutputStreamWriter: both constructors,
  scalar/array/string writes, flush and close. The incremental encoder supports
  the same six charsets, keeps a split high surrogate across writes/flush and
  finalizes malformed input on close. UTF-16 emits its BOM once, including when
  the first nonempty write contains only a high surrogate. Encoding work yields
  in bounded blocks; buffered output uses ordinary virtual OutputStream calls,
  preserving guest exceptions, GC and monitor ownership while callbacks suspend.
  Base Writer convenience methods honor the protected lock. OutputStreamWriter
  serializes encoding/flush/close on its own monitor and retains the supplied
  stream as its protected lock, matching the JDK reference. Close detaches the
  encoder buffer even after errors; the lock still references the output stream
  until the writer is collected. getEncoding is supplied as a small extension.
  StringWriter is another extension, with a live StringBuffer, immutable string
  snapshots and writes after close; it is not part of CLDC 1.1. Java SE charset
  objects, Appendable/CharSequence and the wider SE writer API are not supplied.
- `Java.Numbers` supplies the CLDC Integer wrapper/conversion API and
  NumberFormatException. Byte/Short also provide their CLDC constructors,
  constants, value extraction, equality/hash/text and range-checked parsing.
  Signed parsing validates radix, Unicode decimal digits,
  fullwidth Latin letters and Int32 overflow; formatting supports bases 2..36
  and unsigned binary/octal/hex. Numeric narrowing and int/long/float/double
  extraction are covered. CLDC parsing accepts an optional minus, rejects a plus,
  and valueOf(String) allocates a fresh wrapper as specified by that profile.
  It also supplies the full CLDC 1.1 Long API: MIN/MAX constants, constructor,
  long/float/double extraction, equality/hash/text and both signed parseLong and
  toString overloads. The existing intValue extension remains available. Integer
  and Long share a width-bounded negative accumulator, including the asymmetric
  minimum value, Unicode 3.0 digits and strict sign/overflow checks. Long formatting
  supports every radix2..36 and decimal fallback for invalid formatting radices.
  The parser rejects invalid radices and a leading plus as required by CLDC.
- `Java.Collections` supplies the CLDC Vector API, Enumeration, Stack and their
  exception types. Vector's protected backing array/count/increment fields are
  real guest fields, with dynamic capacity, null components, indexed edits,
  typed copyInto and clearing of discarded slots. Growth failures preserve the
  prior state and report catchable Java allocation errors at VM array limits.
  Search/remove/toString and Stack's composed operations run as verified guest
  methods; virtual equals/toString can yield, throw, GC or reenter the vector.
  Enumeration retains its vector, advances under its monitor and observes live
  storage. Enumeration during mutation has no snapshot/fail-fast guarantee.
  CLDC Vector keeps Object identity equality and is not Cloneable; it does not
  implement the Java SE List/Collection interfaces. String rendering handles
  nulls and a direct self-reference.
- `Java.Hashtable` adds the CLDC Hashtable API with fixed 75% loading,
  linked guest entries, protected virtual rehash, null rejection, guest key/value references
  and key/value Enumeration. Hash/equality/format callbacks run as ordinary guest
  code under the table monitor; a changed version restarts lookups after a
  reentrant callback or a wait that released the monitor. Rehash allocates before
  relinking entries; failed array growth leaves existing mappings intact.
  Enumeration retains its owner/storage, has no mutation snapshot/fail-fast
  promise and yields while scanning long empty bucket ranges. Clear also works
  in bounded native batches. CLDC Hashtable retains Object identity equality,
  without Java SE Map/Dictionary/Cloneable behavior.
- Shared `java/util/Timer`/`TimerTask` use one cooperative Java worker per timer
  and a heap of pending tasks. One-shot/Date deadlines, fixed-delay and fixed-rate
  repetition, cancellation and scheduledExecutionTime are implemented. Guest
  callbacks retain virtual dispatch, thread identity, monitors, instruction
  budgets and GC roots; an uncaught callback exception closes that timer while
  other timers continue. Cancelling a timer discards queued tasks while allowing
  its current callback to finish. TimerTask cancellation prevents further runs.
  Queue growth is bounded at 65536 pending tasks; cancelled-root cleanup yields
  after 64 removals. Pending tasks retain their references, while the worker has
  a weak integer owner handle so an unreachable, empty timer can terminate.
  A private monitor wait is notified by scheduling/cancellation, with a maximum
  one-second interval for wall-clock adjustments and orphan detection. Timers
  have no hard real-time guarantee. Deadlines beyond Long.MAX_VALUE remain
  pending without wrapping or repeatedly firing at the maximum epoch.
- `java/util/Date` implements the CLDC constructors, millisecond get/set,
  equality/hash and text form. Equals/hash retain virtual getTime dispatch;
  toString uses the stored instant. `Java.Dates` shares overflow-safe civil date
  conversion with Calendar, including the Julian/Gregorian transition and BCE.
  Date text uses the host default zone, with four-digit minimum years.
- `Java.Calendars` implements the CLDC Calendar surface: the supported field
  constants, get/set, Date snapshots, comparisons, zones and protected subclass
  hooks/arrays. Factories initialize a hybrid Gregorian calendar from host epoch
  time. Pending edits preserve field precedence, AM/PM versus 24-hour selection,
  Sunday-based weeks and the shortened October 1582. Missing fields default to
  the epoch. Wider SE add/roll/locale/leniency APIs are absent; out-of-range value
  normalization is a compatibility extension, not a strict-validation guarantee.
  Composed methods are verified guest code. Date/Calendar/TimeZone overrides
  preserve virtual dispatch, errors, budgets and GC through resumable native
  continuations with traced reference state.
- `Java.TimeZones` provides GMT/UTC and normalized GMT signed hour/minute IDs,
  unknown-ID fallback, fresh available-ID arrays and offset argument validation.
  `TJavaHost.DefaultTimeZoneID` defaults to GMT and can be overridden per host;
  existing Calendar/TimeZone objects keep their snapshots. Date formatting uses
  the same setting. User TimeZone subclasses supply their own offset/DST rules.
  There is no IANA database or platform time-zone/DST backend yet, and unknown
  named zones fall back to GMT. The advertised finite ID list is GMT/UTC;
  parameterized GMT offset IDs are accepted in addition.
- Shared `java/util/Random` with the specified 48-bit sequence, seeded/reseeded
  integer/long/float/double operations and bounded integer rejection sampling.
  Composed methods call virtual `next`/`setSeed`, including guest overrides.
- Shared InputStream/OutputStream defaults, byte-array streams, DataInput and
  DataOutput interfaces, DataInputStream/DataOutputStream primitive big-endian
  I/O, readFully/skipBytes, modified UTF-8, stream delegation and byte counts.
  EOFException, UTFDataFormatException and UnsupportedEncodingException have
  their proper IOException ancestry. Buffers/references live in the guest heap.
  Additional legacy charsets remain pending; character streams are provided by
  Java.Readers and Java.Writers as described above.
- `Java.Classes` assembles our library's composed methods as normal verified
  guest bytecode, so custom stream implementations and Random subclasses retain
  virtual dispatch, exceptions, scheduling and resumable instruction budgets.
  Native leaf handlers implement buffer access, seed updates and UTF conversion.
  This requires no external JVM binary or Java compiler at runtime/build time.
- Class.getResourceAsStream resolves absolute or package-relative names through
  the embedding host. The J2ME host supplies JAR resources as guest byte-array
  input streams; missing resources return null and empty resources remain streams.
- JAR loading via RetroMul's existing ZIP/storage implementation; main manifest
  sections, continuation lines, JAD overrides, MIDlet enumeration and resources
  with case-sensitive names. Suite members remain available after the input
  stream is closed. JAD URLs are not downloaded.
  Attribute values and comma-separated MIDlet items ignore surrounding HT/SP,
  preserving other Unicode characters. Profiles are a space-separated list;
  every required profile is checked, including after JAD overrides. Folded and
  repeated spaces work, while unknown requirements, inner tabs and NBSP profile
  prefixes remain rejected. This removes VansSkateAndSlam's trailing-space
  MIDP-2.0 profile rejection without a per-game workaround.
- `J2ME.Device` provides validated virtual screen geometry and twelve size
  presets. The frontend's Java ME phone settings expose Screen size plus custom
  width/height. Phone.ScreenSize defaults to custom, preserving existing
  Phone.Width/Height values (240x320 for a fresh configuration); preset selection
  retains those custom values. Unknown stored presets fall back to custom.
  Dimensions are 1..1024. Changes apply when reopening the game; worker frames
  and resets use the effective selected dimensions. These presets describe
  geometry and do not claim a particular physical handset's other capabilities.
- `J2ME.Nokia.UI` supplies initial Nokia FullCanvas and DeviceControl support.
  FullCanvas keeps the entire Canvas viewport, nine Nokia key constants and raw
  key callbacks; commands/listeners are rejected as specified. DeviceControl
  validates backlight/vibration arguments. Its virtual color-phone profile maps
  backlight 0..100 to 20..100% output brightness, preserving image resources and
  the unmodified content buffer. Nonblocking flashes alternate every 250 ms,
  are limited to 30 seconds and restore the latest requested light level.
  Host polling publishes brightness changes even without a guest repaint.
  This profile does not alter the OS monitor. Nokia, MIDP and Siemens now share
  `J2ME.Effects`, an RTL-only virtual backlight/motor model. Valid startVibra calls
  set virtual motor strength/duration; strength or duration zero cancels it.
  The adapter exposes accumulated motor duty through IEmulationRumbleOutput,
  reusing the frontend's existing gamepad/mobile vibration backends. Core/native
  handlers never call platform effect APIs. Pause, stop, fault, restart and rapid
  Pause/Resume cancel motor output; generation checks discard stale worker samples.
  Physical device validation and further vendor APIs remain pending; these
  available classes do not imply the complete Nokia UI API.
- `J2ME.Siemens.Game` implements the documented MelodyComposer, Melody, Sound,
  Light and Vibrator classes,83 integer constants and the internal NativeMem
  superclass used by Melody. Composers store note/length pairs and BPM; constructors
  copy input, getMelody snapshots the score/BPM, and reset does not mutate earlier
  melodies. Scores stream directly into the existing PCM mixer, with14 duration
  codes,58 pitches, rests, stop, restart, markers and six finite/infinite repeat
  commands. Repeat execution retains bounded cursor/counter state and does not
  expand repeated scores or allocate their complete PCM. Static Melody.stop stops
  the current Siemens melody; Sound.playTone uses Hz/milliseconds and a separate
  replaceable tone channel. Playing melodies retain GC roots; allocation pressure
  collects unreachable native score objects before reporting its live-object cap.
  Light and Vibrator use the same state as the Nokia and MIDP APIs.
  Virtual limits/policies:4096 entries per score,256 live native score objects,
  positive BPM (subsample notes quantize to one PCM frame), Sound frequencies
  0..20000Hz and nonnegative durations; malformed
  note pairs/lengths are rejected. C0 maps to MIDI48 in the virtual tone generator;
  a repeat count requests additional passes, terminal repeats stop afterward and
  REPON variants continue. A control-only infinite cycle ends without spinning.
  Vendor documentation leaves absolute pitch calibration, beeper waveform,
  malformed-input details and handset capacities unspecified. These virtual
  choices and repeat edge cases have not been compared with a reference handset.
  They are not claims of hardware-exact Siemens sound or complete Siemens APIs.
- `J2ME.Siemens.Graphics` implements ExtendedImage, GraphicObject, Sprite,
  TiledBackground, GraphicObjectManager and Siemens UI Image with native bodies
  on the existing Image pixel arrays and straight-alpha compositor. Packed MSB
  1bpp/2bpp images, masks, vertically stacked frames, repeating 8x8 tile maps,
  ordered scene painting, rectangular collisions and direct display blits share
  storage with ordinary MIDP graphics. Raw bitmap constructors snapshot input;
  image-based scenes retain the images and maps remain live. Transparent images
  are rejected where the vendor API requires opaque source/mask/destination data.
  Standard Image.createImageFromBitmap supplies the Siemens MIDP1 extension.
  UI Image adds RGB332 (0xC0 transparent), image copies/native-image bridges,
  axis reflections and down-only aspect-preserving nearest-neighbor scaling.
  Resource/encoded-byte loading currently supports PNG; the vendor's additional
  JPG/GIF/BMP formats and other Siemens media/I/O APIs remain unimplemented.
  Raw sprite rows require byte-aligned widths and exact buffer sizes; positive
  frame heights are unrestricted, as used by GP Pinball's 8x5 ball and consistent
  with the documented size/error conditions. The parameter prose alone also asks
  for an eight-pixel height multiple, so this discrepancy is explicitly resolved
  in favor of these usable packed frames. No reference handset was tested.
  Further virtual policies needing handset comparison: initially visible objects,
  live image/map ownership, half-open collision rectangles independent of
  visibility, repeating maps, viewport clipping at the drawing origin and literal
  named-axis reflections (horizontal flips Y, vertical flips X). These are not
  claims of complete Siemens graphics conformance or mobile-game compatibility.
  Unmarked images infer packing from actual alpha pixels; monochrome conversion
  uses luminance/alpha thresholds, rather than a calibrated handset palette.
  A null sprite mask draws every pixel for all3 constructors. GameAPI_Demo title
  strips and BlockBreaker level digits exercise this case; the documentation
  does not explicitly state its null-mask behavior. Independent JDK scenes cover
  both supplied and absent sprite masks; handset comparison remains pending.
  ExtendedImage.setPixels clips packed-image writes at the destination edges,
  retaining the complete source row stride. BlockBreaker exercises negative Y
  while scrolling its wall. Alignment/source-buffer checks precede modification;
  individual pixel operations and getPixelBytes still enforce their bounds.
  Clipping is an explicit model choice based on these real guest inputs; the
  preserved parameter documentation does not define every out-of-bounds case.
- `J2ME.Graphics` supplies Nokia DirectGraphics as an interface on the same
  Graphics object. DirectUtils returns that context and creates mutable ARGB or
  decoded PNG images. Color, alpha, translation, clipping and stroke state are
  shared; ordinary setColor/setGrayScale restore opaque color. Shape drawing and
  image/pixel rendering use straight-alpha source-over, retaining alpha in the
  Nokia mutable images. Ordinary MIDP mutable images still start opaque white.
  DirectGraphics supports counter-clockwise 0/90/180/270 rotations followed by
  vertical/horizontal flips, with anchors applied to the transformed dimensions.
  Triangle/polygon colors do not change Graphics state. Polygon fills use the
  even-odd rule; outline coverage is blended once at shared vertices.
  Native pixel format is 8888 ARGB. All thirteen declared byte/short/int formats
  are supported, including horizontal packed gray and vertical one-bit pages.
  Gray samples use zero for white and maximum for black; byte masks use zero
  for transparent and maximum for opaque. RGB bit fields expand to nearest
  8-bit values; readback quantizes RGB bit fields by dropping low bits. Partial
  packed bytes preserve untouched bits. Pixel scanlengths/offsets are measured
  in pixels, including negative horizontal row strides. Vertical one-bit pages
  require a positive scanlength. getPixels ignores clipping, applies translation,
  and validates both arrays before writes; on-screen alpha reads fully opaque.
- `J2ME.Nokia.Sound` implements Sound/SoundListener with the existing Delphi WAV
  decoder and a native tone/OTA synthesizer. FORMAT_TONE supports the mandatory
  basic and temporary Smart Messaging songs, Unicode titles, pattern definition/
  reuse, finite/infinite repeats, tempo, four scales, volume, duration modifiers
  and natural/continuous/staccato styles. Reserved instructions, truncated data
  and nonprogressing infinite patterns are rejected. The command-end byte stops
  the OTA language; enclosing-buffer bytes after it are ignored, while padding
  inside command parts is still validated. Optional OTA MIDI/digitized/
  polyphonic song types and MIDI disguised as FORMAT_TONE are not accepted.
  Simple frequency tones support 0..13288 Hz and positive 64-bit millisecond
  durations without allocating PCM for the duration. The virtual waveform is a
  sine; natural articulation sounds for 15/16 of a note and staccato for 1/2.
  WAV initialization copies input, decodes in 4096-frame blocks and yields the
  Java quantum between blocks. Concurrent release/reinit invalidates older work.
  Sound state, restart/stop/resume, loop zero meaning forever, exact gain 0..255,
  release/reinit failures and queued listener callbacks are separate from MMAPI
  state. WAV resume retains position; tone resume restarts the song. Default gain
  is 255. Sixteen voices per format are mixed, preempting the oldest when full.
  Active playback and queued callbacks retain GC roots; completion releases them.
  Callback failures are observable through TakeMediaError and do not terminate
  the sound engine. Pausing freezes playback and event delivery. MMAPI/Nokia
  voices sum into one wide accumulator before the final output clamp.
- `J2ME.DateField` implements the MIDP DateField API and Form integration:
  DATE/TIME/DATE_TIME, explicit uninitialized values, Date copies, minute
  precision, mode conversion, inherited Item layout/commands, focus and scrolling.
  Calendar/Date/TimeZone calls use normal guest dispatch through traced native
  continuations. A completed calculation publishes the new value/field snapshot
  atomically. Public mutations and getters share the field monitor across
  yielding callbacks; failures preserve the previous published value.
  TIME setDate accepts input milliseconds in [0,86400000), takes local hour/
  minute in the supplied zone and pins local date components to January1,1970;
  invalid input clears the field. Zone offsets can make the returned instant
  differ from that input interval. Mode changes retain initialization and discard
  components not used by the new mode. There is no system locale/calendar-picker
  backend yet: the software UI displays ISO date and 24-hour time components.
  Fire starts/ends editing, Left/Right selects components, Up/Down changes their
  value while editing, digits replace a component, Clear unsets the value, and
  Tab or Up/Down outside editing traverses the Form. Text input accepts a complete
  YYYY-MM-DD, HH:MM or YYYY-MM-DD HH:MM for the active mode. Valid user changes
  notify ItemStateListener on the serialized UI context; programmatic setters
  do not. Date edits clamp month-end days and the editor year range is1..9999;
  API instants use the wider Calendar range. Narrow fields wrap all date lines
  and scroll the active component into view. Device-specific skins, natural
  language entry and locale-dependent presentation are not claimed.
- MIDlet construction/start/pause/resume/destroy, Canvas dimensions and queued
  key callbacks/repaints, size/show/hide notifications and no-pointer/no-repeat
  capability queries. Lifecycle and serialized UI callbacks have independent VM
  contexts, so a blocking startApp does not prevent UI delivery. Emulation pause
  also freezes a still-running startup without calling startApp a second time.
  MIDlet construction is AMS-owned; protected construction outside the root
  creation is rejected. Notification/property methods are final. `notifyPaused`
  before initial start is ignored; a self-paused MIDlet keeps Java background
  work/timers running, while an emulator pause freezes all VM execution.
  `resumeRequest` coalesces asynchronous requests until lifecycle execution is
  available, respects host pause and never reenters startApp. A transient
  MIDletStateChangeException from start leaves the MIDlet paused for retry.
  Unhandled start/pause failures attempt unconditional destroyApp cleanup and
  leave a drained, bounded diagnostic; MIDletStateChangeException during unconditional destroy
  is ignored. The worker forwards only host pause edges, preserving guest pause.
  Stop can interrupt host pause or suspended startup.
  serviceRepaints performs synchronous guest paint, including nested calls from
  UI handlers/paint; each delivery receives fresh Graphics and remains subject
  to instruction budgets. Hidden/empty/offscreen repaint requests are ignored.
  `J2ME.Graphics` supplies ARGB drawing, translated
  coordinates, clip intersection/query, RGB/gray components, stroke selection,
  rectangles, clipped lines, filled triangles, arcs/pie wedges and rounded
  rectangles. State resets for each paint.
  Line work is bounded by the visible target even at extreme 32-bit endpoints.
  `Media.Raster.Shapes` is an independent RTL-only span rasterizer shared by the
  curved primitives. It clips work to visible rows/columns; integer 128-bit
  products built from 32-bit limbs determine ellipse pixels without overflowing
  large dimensions. A floating estimate is corrected by exact comparisons.
  Angular tests use an integer direction table; thin ellipse outlines are split
  by parameter quadrants before rounding. Filled wedges share half-open edges,
  outlines include endpoints and dotted strokes are subsets of solid strokes.
  Filled primitives ignore stroke style. Negative/empty dimensions and signed
  angle overflow are handled explicitly. Corner diameters use their absolute
  values, clamped to the rectangle dimensions (the selected policy for negative
  corner diameters); zero diameters reduce rounded rectangles to rectangles.
- `J2ME.LCDUI` adds Command/CommandListener, Displayable metadata, Screen,
  Ticker and Choice/List. Commands retain labels/type/signed priority, ignore
  duplicate references and map onto softkeys and a navigable Options menu. Normal
  Canvas softkeys stay reserved regardless of command count; fullscreen canvases
  with a listener expose commands through a popup, and fullscreen canvases without
  a listener can receive raw softkey codes. Keyboard F1/F2 and existing Select/
  Start gamepad/touch bindings reach these softkeys through the worker.
  List supports implicit/exclusive/multiple selection, element CRUD, selected
  flags, fonts/fit preferences, custom/default/disabled select commands and image
  snapshots. Empty lists do not invoke their select command. Kept image snapshots
  are immutable, including when the source image was mutable. Native rendering
  draws actual choices, focus/selection, alpha images and a viewport that scrolls
  to the focused row. Fonts affect row height. Long focused labels, with line
  breaks shown as separators, scroll horizontally; fit policy is retained as a
  preference, with the current renderer choosing this single-row presentation.
- `Alert`/`AlertType` provide title/text/image/type, default and custom commands,
  a default listener that restores the explicit or previous screen, and UI-thread
  timeout delivery. Multiple commands or scrolling content make an alert modal.
  Mutable images retain their original getImage identity and a separate immutable
  display snapshot, refreshed by setImage. Text wraps, scrolls vertically and
  shares the existing title/ticker/command composition. Timers start on rendering,
  are cancelled by a screen change, reject stale queued generations and freeze
  during emulator pause. Command invocation consumes the active timeout; a new
  timeout/content request rearms it. A custom listener controls screen changes.
  A first alert with no previous screen restores the empty platform state.
  AlertType.playSound validates its display and reports false on this host.
- `J2ME.Items` supplies the initial Item base API and Gauge. Gauges clamp definite
  values, validate indefinite states, support continuous/incremental activity
  rendering and preserve Item label/layout/command/preferred-size metadata.
  Alert indicators enforce noninteractive/ownership/label/command/listener/layout/
  size restrictions and prevent those properties being changed while owned.
  Ownership and return-screen references are traced guest fields, not native roots.
- `Form`, `StringItem`, `ImageItem`, `Spacer`, `ChoiceGroup`, `TextField` and
  `TextBox` now provide an initial high-level UI. Forms enforce unique item
  ownership, validate mutations before claiming items, and support append,
  insert, replace, delete, focus and scrolling. Row layout applies newline,
  alignment, shrink/expand and vertical flags; labels occupy a separate block.
  ImageItem uses an immutable display snapshot while retaining getImage identity.
  ChoiceGroup supports exclusive, multiple and popup selection, element CRUD,
  images and fonts. Interactive gauges and item commands share the UI context.
  Item-state notifications coalesce until delivered and precede the associated
  command; detached items and removed commands cannot receive stale callbacks.
- TextField/TextBox implement UTF-16 string/char-array editing, capacity,
  constraints, caret queries and initial-input-mode hints. Failed mutations
  preserve contents. NUMERIC validates signed Int32 values; DECIMAL uses ASCII
  minus/dot/digits without exponent notation. Email/URL permit arbitrary text;
  phone-number punctuation follows the host policy tested in the fixtures.
  Password rendering hides contents; UNEDITABLE blocks user edits. Phone keys
  support multitap, case/digit modes, caret movement and surrogate-pair deletion.
  Desktop A-Z enters lowercase letters, Backspace deletes, Home/End moves the
  caret and Tab advances focus. Runtime.TextInput accepts Unicode strings, but
  frontend IME/text-service integration and complete mobile controls are pending.
  This is initial layout/editing support; CustomItem remains absent.
- J2ME.Network supplies the GCF Connection/InputConnection/OutputConnection/
  StreamConnection/ContentConnection/HttpConnection hierarchy and Connector
  overloads/convenience streams. The initial HTTP transport performs real
  GET/POST/HEAD requests using the host RTL HTTP client on a separate thread.
  Guest native calls suspend/retry while transport runs; the worker never
  accesses the VM. Headers, status/error bodies, URL components, three common
  HTTP date formats and data-stream wrappers are available. Redirect responses
  remain visible to the application. Cookies are not shared between connections.
  Closing a connection preserves already-open streams; stream references keep
  the guest connection alive until close. GC/terminal runtime cleanup cancels
  unused work; results are published only after an interlocked completion signal.
  Interrupted guest waits produce InterruptedIOException. The J2ME host currently
  installs this Java exception alongside ConnectionNotFoundException.
  MIDlet.checkPermission permits the implemented HTTP API and denies unknown
  permissions. platformRequest accepts empty-string cancellation, rejects null,
  and otherwise throws ConnectionNotFoundException because no external-app
  handler is connected; it does not launch a browser or dialer.
  This transport buffers the whole request and response, up to the smaller of
  8 MiB and VM.MaxArrayLength. The first flush/close/response query commits the
  request body; subsequent body writes fail. Streaming uploads/downloads, HTTPS
  SecurityInfo/certificates, sockets/datagrams and JSR-75 files remain
  pending. There are limits of 32 live connections, 16 outstanding jobs, 128
  request headers/64 KiB total and 16 KiB URLs; host I/O timeouts are 10 seconds.
- `J2ME.Resources` implements read-only `resource:` GCF connections using the
  suite's JAR loader. Legacy backslash separators are accepted only in these URLs;
  case-sensitive resource names and literal percent/query/fragment characters
  remain JAR keys. READ and default READ_WRITE produce InputConnection objects;
  WRITE is rejected. Multiple streams have independent positions, mark/reset,
  bounded skip and EOF/bounds checks. Closing a connection prevents new streams
  while existing streams retain the buffer; closing a stream drops its data and
  connection references. Guest GC owns all state, without native handle tables.
  Missing resources produce ConnectionNotFoundException, archive extraction
  failures produce IOException, and array-capacity failures produce guest
  OutOfMemoryError without faulting the VM.
  The MIDP host now canonicalizes dot/parent components inside the JAR and hides
  `.class` members from resource reads. Class lookup retains its separate loader.
  The shared Java host exposes virtual LoadClassResource and JavaClassResourceName;
  its default preserves the existing unrooted resource-key contract and allows
  classfile resources. MIDP restrictions stay out of the reusable JVM/library.
  Ordinary nonclass data named `data.CLASS` remains case-sensitive data.
  The preserved Siemens Connector page does not specify `resource:`. URL spelling,
  mode/interface shape, multiple-open and mark/close policies therefore remain
  explicit virtual choices requiring handset comparison. No host filesystem
  protocol, JSR-75 support or complete GCF conformance is implied.
- J2ME.Bluetooth.Data implements initial UUID/DeviceClass/DataElement APIs and
  Bluetooth exception/status types. DataElement validates integer widths/types,
  owns byte-array snapshots, returns defensive byte copies, and exposes live
  sequence enumerations rooted in the guest heap. Cycles may exist in ordinary
  guest sequences; bounded copying/SDP publication rejects cyclic graphs.
  Core.Bluetooth.SDP is an RTL-only binary codec with big-endian fields, scalar
  widths, UUID forms, variable payload lengths and nested sequences/alternatives.
  It rejects malformed/truncated/trailing input and enforces 1 MiB, 32 nesting
  levels and 65536 nodes. The guest bridge preserves UTF-16 while copying
  records and uses UTF-8 only at the SDP wire boundary.
- J2ME.Bluetooth provides LocalDevice, RemoteDevice, DiscoveryAgent/Listener and
  initial ServiceRecord access. An absent/disabled/unapproved provider causes a
  catchable BluetoothStateException; the LocalDevice class does not fail static
  initialization. Device/name metadata, inquiry access codes, paired/cached
  lists, asynchronous inquiry/service search, cancellation and result/error
  codes pass through the provider. Optional IBluetoothClassicControl preserves
  explicit inquiry codes, name refresh and discoverability semantics.
  Duplicate devices are suppressed per inquiry, UUID search filters are
  deduplicated, and mandatory SDP attribute IDs are included in searches.
  Records return defensive attribute/ID copies, form connection URLs from
  actual endpoints and can populate requested remote attributes. Connections
  use the shared provider through J2ME.Bluetooth.Transport as described above.
  Listener callbacks use ordinary guest invokeinterface dispatch on a separate
  persistent execution context; they may yield/GC/throw without replacing the
  UI/lifecycle context. Callback errors are observable through TakeBluetoothError,
  the worker and the diagnostic probe. Pause defers event consumption/delivery;
  cancellation discards queued results and reports termination. Pending jobs and
  queued arguments retain explicit roots, released after completion/cancellation.
  Queues/caches/search counts are bounded, and malformed/over-quota metadata
  produces completion errors. Complete physical interoperability remains
  unfinished; supported transports, service registration
  and security operations depend on the selected provider's capabilities.
- Canvas drawing uses a separate content buffer and logical viewport; title,
  scrolling ticker and command bars are composed around it. Fullscreen hides
  title/ticker/bar chrome without clearing their properties. GameCanvas buffers
  keep maximum phone dimensions even when constructed while another displayable
  has smaller content; only the current content region flushes to the screen.
  Graphics, sprites and layers use the same content destination. Fresh display
  Graphics capture logical height, and layout is checked again before painting;
  sizeChanged may yield or change the layout recursively. Pending repaint cycles
  complete before their queued Display.callSerially runnables. Commands, keys,
  serial runnables and queued display callbacks retain guest dispatch, GC roots
  and the persistent serialized UI context. Lifecycle execution stays independent;
  synchronous serviceRepaints retains caller-thread paint as permitted by MIDP.
  Popup menus hide the Canvas,
  clear game key polling and restore visibility after closing; stale visibility
  requests are discarded when a later setCurrent supersedes an earlier request.
  setCurrent(null) preserves the current displayable. Display.vibrate and
  flashBacklight now report the emulated motor/backlight capabilities, use the
  shared phone-effects state and accept zero as cancellation. Invalid negative
  durations still throw. Their return values describe the virtual device, not the
  presence or permission state of a physical host actuator.
- `J2ME.Image` implements mutable white images, immutable snapshots, ARGB image
  creation, PNG loading from byte arrays/JAR resources/custom InputStreams,
  getRGB including negative scanlength, and all eight MIDP region transforms.
  Graphics can target mutable images; their pixels and target references are
  ordinary guest heap fields. drawImage/drawRegion/drawRGB implement clipping,
  anchors and source-over alpha; copyArea snapshots overlapping source regions.
- Shared `source/media/image/Media.Image.PNG` decodes grayscale, RGB, indexed,
  gray-alpha and RGBA at legal 1/2/4/8/16-bit depths, all filters, Adam7 and tRNS.
  It checks chunk CRC/order/bounds and exact zlib output under pixel/input limits.
  It uses the standard Delphi RTL ZLib, with no separate third-party binary.
  Optional colour-profile/gamma ancillary chunks are ignored as permitted by MIDP.
- `J2ME.Font` implements font attributes, metrics and range checks, plus graphics
  text/character methods, font selection and baseline/top/bottom/center anchors.
  J2ME uses native-size RetroMul Pixel bitmaps through `Media.Font.Bitmap`,
  with 1356 Unicode glyphs at each of 12/16/24 pixels and matching baseline/advance
  metrics. It preserves strokes in small fonts and includes Cyrillic. Font data
  derives from Terminus under SIL OFL 1.1; original glyph bits and the complete
  license are embedded as resources. Provenance is in `source/media/image/fonts`.
  Dreamcast keeps `Media.Font.Hershey`; its original glyph bytes are preserved
  independently on Win32 and Win64. Styles and device font sizes are initial
  system-font choices, not reproductions of a particular phone's typography.
- GameCanvas has a retained mutable white buffer, fresh Graphics per getGraphics,
  clipped full/partial flush snapshots, paint delivery, held/latched game keys,
  physical-key aliases and optional suppression of game key callbacks.
- Layer, Sprite, TiledLayer and LayerManager support positioning/visibility,
  frame sheets/sequences, copy construction, reference pixels, eight transforms,
  collision rectangles, bounding-box and opaque-pixel collision, static/animated
  tiles, layer ordering and view windows. LayerManager calls virtual Layer.paint
  as guest bytecode and restores Graphics clipping/translation even on exception.
  Layer/image/tile references and sequences are ordinary GC-traced guest fields.
- Initial RMS RecordStore persistence, RecordEnumeration, filter/comparator and
  record listener interfaces with the RMS exception hierarchy. Stores are keyed
  by the exact MIDlet-Vendor/MIDlet-Name plus case-sensitive store name, independent
  of JAR location/version. Raw UTF-16 identities are length-prefixed and SHA-256
  hashed for safe paths, including NUL, slashes and surrogate code units in names.
  The suite retains its supplied IStorage, keeping saves in that storage's
  SaveRoot/j2me/rms. A checksummed RMRMS001 snapshot preserves IDs, version/time,
  sharing mode and records. Mutations use existing atomic flushed replacement;
  malformed/checksum-invalid data is reported instead of silently reset.
  OS locks serialize processes and hold shared leases until final close; deletion
  fails while any process has an open lease. Recursive first-launch directory
  creation tolerates another process creating the same component. Repeat opens
  within a VM share the guest object and require balanced closes. Last close
  drops listeners and invalidates old enumerations, including after reopening.
  Private/shared and read-only/writable access is checked at open, with owner-only
  mode changes. IDs are monotonic and deleted IDs are not reused.
- RMS enumerations support snapshots or version-checked kept updates, both
  directions, reset/rebuild/destroy, guest filters and stable bottom-up merge sort
  with guest comparators. Callback state lives in traced guest fields; calls may
  yield, collect, mutate stores or throw. Native sort work yields in bounded
  blocks. Same-handle listeners run on the mutating guest thread after commit;
  other live VMs in the same process receive queued callbacks through a separate
  execution context. Listener faults in that context are diagnostic and later
  callbacks continue. VM destruction, guest destruction, faults and stop release
  leases; stopping a yielding RMS callback does not discard committed records.
- Initial MMAPI Player/Manager/Controllable, player listeners, VolumeControl and
  the system TimeBase. WAV and MIDI reuse the existing native Delphi music
  decoders; MIDI uses its SoundFont synthesizer. Realize/prefetch/start/stop/
  deallocate/close, seek, finite/infinite loop counts, stereo mixing/resampling,
  volume/mute, type sniffing and resource: locators are implemented. InputStream
  creation reads through virtual guest methods, including custom yielding streams.
  Realization processes bounded decoder blocks in a guest loop and yields to the
  host, allowing cancellation, GC and other threads to progress. Listener events
  have a separate persistent VM context and boxed Long media times. Listener faults
  are reported through media/audio diagnostics while later callbacks continue.
  Unstarted players follow guest GC; started players stay rooted until stop/end/
  close. Retained controls/listeners are GC-traced. Manager.playTone generates
  the requested MIDI-note pitch and duration.
- The J2ME worker advances a 44100 Hz media clock and sends actual PCM through
  existing PCMAudio backends, applying master volume/mute. Global pause freezes
  media time and clears device audio. Device failures use
  IEmulationAudioDiagnostics and do not stop Java execution. RenderAudio supplies
  deterministic headless PCM. J2ME.Media embeds the shared TimGM6mb
  bank and its full license/attribution as RCDATA, shared by all target platforms.
  The bank is parsed lazily for the first MIDI, only when no SF2 is found beside
  the executable. An explicit SetMidiSoundFont selection has priority; existing
  decoders retain their immutable bank after a selection change. Other users of
  the MIDI decoder do not acquire this resource automatically. Embedded resource
  bytes and rendering are verified on Windows; mobile runtime remains unverified.
- An experimental `j2me` platform and worker adapter, screen size and MIDlet
  index settings, direct numeric/arrows/Enter/F1-F4 keyboard input and basic
  gamepad input. Existing GB virtual controls and Fluent Games icon are reused.

## Explicit limitations and next implementation steps

This is a working foundation, not yet a compatible CLDC/MIDP implementation.
Broader adversarial verification/linkage coverage and the remaining base library
are required before claiming a complete JVM/CLDC profile. The embedding API is
trusted: callers must supply compatible reference arguments and root retained
objects. Separate guest ClassLoaders and loading constraints between them,
java.lang.reflect, JNI, method handles, invokedynamic and JIT are not implemented.
Verification has explicit state/work resource limits; exceeding those is reported
as an implementation limit, not a proof that a class is invalid.
Unknown classes, methods and bytecodes produce errors instead of fabricated results.

The Java ME host still lacks CustomItem and complete high-level-control
coverage, complete MMAPI,
complete GCF/network protocols, phone vendor extensions, pointer input and state
snapshots. Further Display APIs and the complete
application-manager/display lifecycle remain pending. The bitmap font covers 1356
Unicode glyphs; unavailable glyphs use an explicit replacement. Complex shaping
and full Unicode font coverage remain pending. JPEG/GIF/BMP decoding is not part
of the initial Image implementation. Snapshot support is
explicitly disabled. Background Java threads now run between MIDlet callbacks;
global emulation pause suspends their execution. Complete application-manager
state transitions and display notifications remain to be implemented.

Initial RMS limits: 1 MiB per record, 16 MiB per store, 64 MiB and 1024 stores
per suite, and 65536 records per store. Commits currently replace a whole store;
large-store write performance has not been tuned. Kept enumerations check the
stored version at use. Cross-process operations and enumeration refresh are
serialized, but cross-process RecordListener notifications are not implemented;
queued listener delivery covers VMs within this process. Transactions now wait
for the root lock without an arbitrary two-second failure; native callers may
set LockTimeoutMillis explicitly. Windows queues an overlapped LockFileEx request,
and retires it before releasing its OVERLAPPED/event after cancellation or timeout.
POSIX retries only contention/interrupted flock errors. Pending root/process-gate
waits observe cancellation; the Java bridge observes atomic JVM RequestStop and
TThread termination, with an external-thread guard. Notification/lease metadata
has a separate short-held gate so polling another VM's notifications does not
wait for file I/O. Adapter stop exits before publishing errors from a cancelled
tick. The shared VM exposes only a generic thread-safe StopRequested query.
Native store reads/commits still run synchronously and may exceed a VM tick's
time budget; fully asynchronous persistence remains work to do. Cancellation of
waiting does not undo a commit already in progress. Legacy emulator save formats, migration,
MIDlet uninstallation cleanup and reclaiming orphan files after an interrupted
commit are not implemented. Native Windows process/locking tests run on the host;
POSIX locking has been compiled but requires runtime/device validation.

Current MMAPI is audio-only WAV/MIDI plus playTone, resource: locators and the
default time base, with a finite decoded PCM cache. ToneControl sequences,
MP3/AMR/other formats, MIDI/rate/tempo/metadata/video/capture controls, custom
time bases and other protocols remain pending. Limits are 128 live players,
16 MiB encoded data per player / 64 MiB total, 8 million decoded samples per
clip / 32 million total, 64 listeners per player and 64 simple tone voices.
Exceeding limits reports an implementation/resource error. Device audio latency
and sustained real-game A/V timing have not been validated.

The current one-second startup probe (`probe-collections-corpus.tsv`) uses 31 JARs
from `H:\ROMS\j2me`. It records twelve JARs with published frames; Bounce Tales remains a white screen and is not
a successful game startup. A one-second frame count is sensitive to startup timing.
Earlier bounded scenarios remain historical evidence:
Oldsnake previously blocked in startApp;
a bounded Fire/arrow-input run now produced 18 frames, showing arena-size prompts,
moving snake segments and the game's normal exit screen in about seven seconds.
PuCZlle's latest 15-second input probe produced 14 frames without a VM error.
Krish Cricket now advances beyond String.getBytes: a 15-second input probe
produced 139 frames and reached team selection; a 60-second repeat produced
558 frames without a VM error. A prior longer run encountered a child-thread
ArrayIndexOutOfBoundsException; it was not reproduced by that repeat and is
still under investigation. After MMAPI installation, a 60-second input run
produced 675 frames without a VM error and reached a batting-order screen.
The in-game probe observed zero nonzero PCM samples; sound from this game is
not established. Its code requests /hit.wav while the JAR's entry is res/hit.wav;
resource names remain exact. A separate guest-MMAPI resource probe decoded that
actual WAV and all 18 MIDI resources from Hawaiian Beach Volley/Aircraft Gear
to nonzero PCM. Resource decoding is distinct from successful in-game playback.
These are exploratory input/frame observations, not verified sustained gameplay.
After RMS, a 15-second input probe produced 461 FIFA Football 2005 frames and
reached a Round 1 Argentina/Brazil screen. Aircraft Gear produced 173 frames and
reached an Enable Sound prompt. These observations do not prove either game can
complete a match/level or play audio. After LCDUI commands were added, a 15-second
softkey-input run reached the Blocks/FallingBlocks game board (45 frames each)
and TronCycle's Ready screen (40 frames). Hawaiian Beach Volley produced 88 frames
and 142579 nonzero PCM samples through the game's actual MMAPI path in that run.
An earlier softkey scenario reached 98 frames / 598832 nonzero samples in 20.056
seconds before a child stopped on missing Graphics.fillArc. A separate 60-second
Fire/arrow-only scenario stayed at Enable Sound (598 frames, zero nonzero PCM),
showing that generic Fire does not substitute for that game's Yes softkey.
Bounce Tales remains on a white Canvas even after 15 seconds; its runtime is
active, and its initialization/input path needs further investigation. Gomoku now
reaches an index-22/length-22 guest array exception. Earlier VideoPoker
fillRoundRect failures have been removed. Subsequent Reader/InputStreamReader, PrintStream/System.out and Alert work removed
those earlier blockers. Form/TextField/ChoiceGroup work subsequently removed
further startup blockers. Shared Writer streams are now present; M3G and further
exception types remain missing. The initial Nokia FullCanvas/DeviceControl
continuation removes the FullCanvas class gap; other Nokia APIs remain pending.
The probe observes both
instruction and wall-clock limits, allows guest sleep timers to advance and
reports uncaught child exceptions. Do not infer broad game compatibility from
the diagnostic MIDlets or this one bounded run.

## Reproducing checks

Working files are under `codex-work/jvm-j2me`:

1. `python codex-work/jvm-j2me/prepare.py` compiles the Java fixtures using an
   installed JDK and writes complete Delphi console projects. Test API stubs are
   compile-only and are not included in the diagnostic JAR or runtime.
2. `codex-work/jvm-j2me/build-checks.ps1` builds and runs JVM/J2ME checks with
   MSBuild for Win32/Win64 Debug/Release. The JVM checks compare 137 Java method
   results with JDK output and check CLDC code-unit reversal separately,
   including 27 threading scenarios at four quantum
   scales, and additionally check GC roots, transient strings,
   malformed inputs, execution budgets, stop and instance isolation. A threaded
   diagnostic MIDlet tests wait/notify, collection, pause/resume and background
   repaint through the same J2ME host used by the adapter.
   Another 47 assembled class fixtures cover malformed/type-unsafe bytecode and
   valid edge cases. Their Java SE acceptance is checked independently with
   `java -Xverify:all`; CLDC-only map failures are explicitly distinguished because
   Java SE ignores that attribute. Invalid and unused invalid methods are also
   checked for rejection before field writes or class initialization.
   Another 50 executable class fixtures compare results or exact Java error types
   with JDK 17: access, protected receivers, method selection, final/cyclic
   hierarchies, missing members, opcode mismatches, interface field precedence,
   ACC_SUPER, clone, field narrowing and caught linkage errors.
   A separate290-case JDK comparison verifies final-field writes at45.0/45.3
   through53.0: same/foreign declaring classes, static/instance fields, all
   primitive/reference categories, helper/direct initializers and null/opcode
   precedence. The52/53 cases use explicit DefineClass test inputs; normal JAR
   loading retains its51 cap. `JVMChecks --final-fields classes` runs this subset.
   Library checks include seeded Random sequences and subclass overrides, custom
   streams, primitive I/O, byte counts, malformed/oversized modified UTF-8,
   bounds/EOF, resource name resolution/empty resources and buffers surviving GC.
   String checks compare searches, char arrays, comparisons, replacements/case,
   trim and property error contracts with JDK 17. Builder checks add character/
   slice/index boundaries, capacities, zero filling, immutable snapshots, object
   callback/reentrancy, self append and growth-failure atomicity. JDK 17's stale
   toString cache after append(Object self) is invalidated with a no-op character
   write before comparing its actual contents; stale cached output is not copied.
   Class checks compare names/mirrors, initialization, access, yielding/throwing
   constructors, arrays without component initialization, two-thread contention
   and repeated missing-dependency/wrong-name/truncated/type-unsafe class files.
   Runtime checks cover singleton/access/memory/GC contracts, measured live
   array/text/field storage, logical capacity expansion, collection and isolation.
   Main/worker exit tests verify status, whole-VM stop, rejected new contexts and
   that guest catch/finally blocks do not run. J2ME checks verify Destroyed rather
   than Faulted and terminal cleanup for all three exit paths.
   Independent context checks cover
   result lifetime/GC, identity, reuse, local exceptions and global stop while
   the main callback keeps running.
   Another 220876 independent JDK charset fixtures check all one/two-byte UTF-8
   inputs, each individual UTF-16 code unit when encoded to UTF-8/UTF-16, and
   deterministic random longer data for the six supported charsets. Java API
   checks cover constructors/slices/snapshots, null/bounds/unknown encodings,
   BOM and aliases. Separate JDK runs with UTF-8 and ISO-8859-1 defaults verify
   independent embedding hosts. Codec allocation limits are checked separately.
   Writer fixtures compare 1008 encoding/chunk/flush scenarios with JDK output,
   including malformed/split surrogates and empty/BOM cases. UTF-8, Latin-1 and
   UTF-16 host defaults are checked independently. Virtual stream callbacks yield,
   collect garbage and report lock ownership. The tests cover write/flush/close
   failure combinations, monitor release after errors, concurrent close, a
   four-byte encoder buffer, rejected allocation below that quota, StringWriter
   snapshots/live-buffer semantics and stream lifetime after dropping a writer.
   Character checks compare every BMP code unit and 44 radices against an
   independent, uncompressed Java reader of UnicodeData-3.0.0.txt. A full guest
   grid checks actual static dispatch; wrapper/Hashtable checks run with tiny
   quanta and frequent GC. Separate CLDC fixtures check Latin-1 classification,
   post-3.0 unmapped characters, code-unit String case/ignore-case rules and
   parsing consistency. The 1559 differences from the current JDK's properties,
   simple mappings or decimal values are recorded explicitly rather than using
   that newer Unicode version as the CLDC oracle.
   Math compares all 20 public overloads with 177809 independent JDK cases,
   including raw random float/double patterns, full-exponent arguments, neighbors
   of pi/2 multiples, NaNs/zeros/infinities/subnormals, integer boundaries and
   angular conversion. Non-trigonometric results are bit-exact after Java NaN
   canonicalization; trig permits two ULP and currently observes at most one.
   Guest calls check dispatch and arithmetic; borrowed-FPU tests check results
   and restoration after normal, budgeted and faulted execution. Boolean checks
   exercise first-use concurrent initialization, constructor identity, hashes,
   Hashtable use, tiny quanta/GC and isolated per-VM constant objects.
   Dedicated JAR/JAD fixtures verify HT/SP trimming and profile lists/rejections,
   folded values, JAD override validation, MIDlet item values and retained NBSP.
   The diagnostic MIDlet also reads resources through the real JAR host.
   Calendar/TimeZone compare 3068 independent JDK cases: random full-range longs,
   offset zones, BCE/1582 boundaries, ordered/random field edits, missing fields,
   Date snapshots, comparisons, virtual subclasses and custom DST rules including
   transition ambiguity. Custom calls yield and run with GC between individual
   instructions. CLDC field bounds and fixed-zone argument failures are checked
   separately, as are fresh ID arrays, configured defaults and VM isolation.
   The lifecycle suite covers final/constructor access, guest/host pauses,
   background/timer resume requests, coalescing, suspended startup, transient
   start rejection, fatal cleanup/diagnostics and stop while host-paused.
   Its Canvas additionally checks graphics state reset and exception contracts;
   expected pixels check clipping/translation, an extreme-coordinate line,
   a filled triangle and a zero-size rectangle outline.
   The fourth diagnostic MIDlet covers Image factories, custom stream decoding,
   PNG resources, mutable/immutable snapshots, eight transforms, alpha/anchors,
   copyArea, getRGB strides, errors, retained Graphics/GC, font attributes/styles,
   metric consistency and matching text rasterization across anchor/range APIs.
   Another 51 PNG fixtures cover all colour/depth/interlace/filter combinations,
   16-bit pre-resampling tRNS comparisons, malformed data and truncated prefixes.
   37 valid PNG fixtures are independently compared with JDK ImageIO; grayscale
   sample comparison avoids SE's gray-to-sRGB conversion, and gray tRNS is checked
   separately against explicit source-sample expectations in the native fixtures.
   FontBaseline also builds/runs in each Windows configuration and checks the
   pre-extraction Dreamcast font hash for that architecture.
   The suite has ten entries, including Game API, blocking-startup, repaint,
   media, RMS, LCDUI and curved-primitive diagnostics. There are 125 Sprite/TiledLayer/LayerManager assertions, plus
   GameCanvas buffer/key/flush checks. UI tests verify frames and keys during
   blocking startApp, startup pause/resume, persistent UI thread identity,
   synchronous/nested repaint, caught paint exceptions and independent Graphics.
   Text rendering compares a whole string with individually drawn characters;
   this reproduced and guards against equal-size glyph mask accumulation.
   Media checks verify actual guest calls, exact WAV PCM, loop/event ordering,
   volume/mute/clipping, 22050-to-44100 conversion, A440 frequency, tone duration
   and nonzero MIDI/SoundFont output. They cover virtual streams/snapshots, seek,
   close, cancelled realization, empty media, unstarted GC versus playing-player
   retention and listener fault isolation. A recording device checks worker PCM
   delivery/master volume, pause/resume and nonfatal device failure diagnostics.
   Physical speakers are not exercised by these checks.
   RMS checks execute guest CRUD, metadata, unusual names, empty records,
   reference-counted opens, invalidation, stable sorting/filtering, callback
   exceptions/GC/yield/reentrant mutations, snapshots/kept updates, threads,
   cross-suite authorization and same-process cross-VM listeners. Listener fault
   isolation and stop/lease cleanup are checked separately. Saves are reopened
   after VM teardown and by a newly launched executable. Native fixtures cover
   every truncated prefix/one-byte mutation, a real failed Windows atomic rename,
   unchanged IDs/version on failure, record limits, two concurrent processes,
   delete-while-open and lease release after terminating a child process.
   LCDUI checks cover Command metadata/errors and extreme priorities, Choice
   CRUD/flags/images/fonts, all three List interaction modes, softkeys/menu,
   empty/disabled select commands, serial callback order/thread identity/GC,
   visibility, recursive layout changes, Canvas clipping and sprite destination,
   alpha UI images, large-font/long-label scrolling, maximum GameCanvas buffer
   size and partial viewport flushes. A worker test goes from Canvas through an
   F1 command to List, navigates and selects with Fire, then returns to Canvas.
   Hashtable tests compare 56 contracts and 1800 deterministic mixed operations
   with the JDK, including collisions, iteration order, growth, callback/exception
   dispatch, rehash overrides and monitor contention. VM-specific cases check
   CLDC identity semantics, array-quota failures, value/Enumeration GC, reentrant
   key/value changes and concurrent table changes while a callback waits.
   Byte/Short checks include all 256 byte values and sampled short values across
   bases 2..36, constructors/equality/hash/text and parse bounds/Unicode digits.
   Integer tests compare 800 random Int32 values across all 35 radices, plus
   boxing/narrowing/float bits, unsigned representations, sign/bounds/Unicode
   contracts. Separate checks distinguish CLDC sign/factory rules from modern SE.
   Collection/string-value tests compare 1200 deterministic mixed vector
   operations and 2500 int/long/char conversion triples with the JDK. They check
   all CLDC Vector/Stack operations, protected fields, capacity policies, array
   copies/type failures, live enumeration, virtual callbacks, monitor contention
   and reentrant mutation. Separate VM checks cover CLDC identity semantics,
   allocation-failure atomicity, removed-slot GC and Enumeration roots. Array
   Object conversions and private-shadow native callbacks have explicit cases.
   Timer tests use independently controlled epoch/monotonic clocks. They cover
   argument/state contracts against the JDK, all six scheduling overloads,
   yielding/throwing virtual Date getters, heap ordering/cancellation, fixed-rate
   catch-up versus fixed-delay drift, independent/serialized/sleeping callbacks,
   cancellation during a callback, thread exceptions/interruption, GC of an
   orphan owner, large cancelled queues, negative clock changes and maximum-epoch
   deadlines. Date strings are compared with 1011 independent JDK GMT results,
   padding years shorter than four digits to the CLDC requirement.
   Curved-primitive checks execute 240 JDK AWT tolerance envelopes and 120
   independently computed 90-digit BigDecimal masks for extreme dimensions.
   AWT is a geometric comparison, not an exact MIDP pixel oracle. Additional
   assertions cover full-turn angle independence, clockwise/counterclockwise
   ranges, adjacent pie partitions, fill/outline enclosure, rounded-rectangle
   reductions, clipping/translation, dotted subsets/phase, unchanged graphics
   state and actual Canvas output. The complete fixture runs 1,656,658 assertions.
3. `python codex-work/jvm-j2me/verify_sources.py` checks source encoding,
   dependency boundaries, project XML, configuration registration and imports.
4. `codex-work/jvm-j2me/build-frontends.ps1` builds both frontends into separate
   directories in `codex-work`; it does not replace deployed executables.
5. `inventory.py H:\ROMS\j2me` creates a read-only inventory. `J2MEProbe` accepts
   a UTF-8 list of JAR paths and an output TSV path for bounded startup probes.
   `build-probe.ps1` builds that tool in all four Windows configurations.
   PNG frames are saved under `frames/<report-name>/`. An optional third argument
   specifies up to 60000 ms of exploratory Fire/arrow input. An optional fourth
   argument is a comma-separated sequence of Java key codes, for example
   `"-6,-5,-2,-5"` to exercise softkey menus. Runtime state is included in reports. Without a duration argument the probe
   still observes the full one-second budget after a first frame, so later child
   errors are reported. It saves the first 32 observed frames as well as first/
   last snapshots. This is a diagnostic input script, not an automatic playthrough.
   The optional fifth argument selects the MIDlet index. The optional sixth
   argument delays the first scripted key in milliseconds (default 1000).
   A seventh argument `once` stops input after one sequence; zero entries wait
   without delivering a key. This permits selection followed by loading pauses.
   A final `*-threads.txt` snapshot records bounded guest stacks, thread states,
   deadlines and monitor/class waits; it does not alter guest scheduling.
   An optional eighth argument --trace-exceptions writes caught/uncaught Java
   throw-site diagnostics to *-exceptions.txt. The probe caps its saved list at
   1024 entries and reports both VM-ring and probe-list omissions. An optional
   ninth argument WIDTHxHEIGHT sets the virtual screen and PNG dimensions;
   use --no-trace in the eighth position when only specifying geometry.
   The default remains 240x320 and each TSV result now includes the chosen size.
   Probe snapshots also include bounded local references and field/array sizes
   (no string contents). `*-timings.txt` separates runtime ticks, audio rendering
   and PNG frame saving, including for failed runs.
   The startup probe also advances headless media and reports nonzero PCM counts.
   J2MEAudioProbe accepts the diagnostic fixture JAR, a UTF-8 real-JAR path list
   and an output TSV. It runs each WAV/MIDI resource through guest Manager/Player,
   reports duration/nonzero samples and saves the first two seconds as WAV in
   audio-probe-pcm. It does not execute the real game's startup/lifecycle.

6. `python codex-work/jvm-j2me/verify_rms.py` independently parses the persisted
   files from all four Windows check runs and validates SHA-256, hashed identities,
   IDs and actual saved record contents. `verify_rms.py --stress 24` repeatedly
   starts two fresh native writer processes to expose first-use directory and
   locking races. Each pair must persist exactly 48 records without ID gaps.
7. `codex-work/jvm-j2me/build-portable-units.ps1` compiles the J2ME adapter and
   dependencies for Android 32/64, Linux64, macOS x64/ARM64 and iOS device/simulator
   ARM64. This is unit compilation, not linked/deployed application validation.

The curved-primitive follow-up removes the fillArc/fillRoundRect blockers:
Hawaiian Beach Volley reaches an actual court with players and ball in a
60-second softkey/Fire/arrow scenario (469 frames, 2568894 nonzero PCM samples,
no recorded guest exception). VideoPoker renders a five-card deal in a
30-second scenario (45 frames) before its Options menu. HighSpeed3D publishes
914 frames before failing on the missing `javax.microedition.m3g.Group`.
These observations do not validate a full match/hand, physical audio or mobile
play. Reports are `probe-shapes.tsv` and `probe-shapes-hawaiian-play.tsv`;
frame evidence is in their corresponding `frames` subdirectories.

The collection/integer follow-up starts Spacefighter's actual level after Fire
in the menu and then numeric 0 (464 frames in 45.005 seconds). Frames 22/30/32
show moving objects and shots; after losing a life its final screen requests
continuation with two lives remaining. A Shooter numeric-input scenario reaches
its normal end screen with 204 points and notifyDestroyed (96 frames, 33.045
seconds), without a recorded guest exception. These runs emitted no nonzero PCM.
Evidence is in `probe-spacefighter-integer.tsv`, `probe-vector-play.tsv` and their
`frames` directories. At that stage Sea/Pinball were blocked on PrintStream/System.out;
the two probed Tetris JARs had reached missing Hashtable. The Hashtable/Byte
follow-up reaches the EA game board with nonzero PCM (82 frames in 30.008 seconds);
the other Tetris then required Reader/InputStreamReader. This is not yet a
completed-level or device/audio-output validation. A separate 60-second input
scenario reached the help screen without a guest error (139 frames, 759330
nonzero PCM samples); it is menu-navigation evidence, not a level playthrough.

The Reader/diagnostics follow-up removes those stream/console blockers:
Tetris-2.1.3 reaches an actual board (110 frames, 45.003 seconds, score 34 in the
final frame); its caught Started player error prints an origin trace and the
application continues. Numeric 1 starts Pinball Dreams and reaches its table
(336 frames, 30.060 seconds). Neither probe emitted nonzero PCM. The Alert follow-up
runs Sea.jar for 30.002 seconds with 188 frames and no recorded guest error;
its small monochrome viewport stays at the top-left of the configured 240x320
screen, so correct resolution/gameplay/audio are not established. An Alert
visual fixture displays wrapped text, mutable-image snapshot, animated Gauge
and a dismiss action. Reports are probe-diagnostics-tetris-final.tsv,
probe-pinball-print-play.tsv, probe-sea-alert.tsv and probe-alert-visual.tsv.

The Form continuation runs Snake Evolution, Robobouncer and Diccionario
Castellano for 10 seconds each without a recorded uncaught exception. Their last
frames show the Snake arena (117 frames), Robobouncer title (4 frames) and a
dictionary search Form with TextField (189 frames). No nonzero PCM was recorded;
these runs do not establish sustained play, dictionary lookup or audio. Snake
III stopped on missing javax.microedition.io.ConnectionNotFoundException at
that milestone. The GCF continuation supplies that type; the next observed
startup blocker was javax/bluetooth/BluetoothStateException (no game frame).
The initial JSR-82 classes now remove that block, and shared StringBuffer/
StringBuilder delete/deleteCharAt remove a subsequent string-library failure.
Snake III next stops on missing javax/microedition/m3g/Node; no game frame,
gameplay or audio is established by this startup run.
The separate Form visual fixture renders wrapped text, a name editor, gauge,
checkboxes, popup and commands. Reports: probe-form-games.tsv and
probe-form-visual.tsv. Form.Cases checks ownership/atomic failures, an independent
JDK reference for 2500 text mutations and constraint cases, password frame
equality, UTF-16 editing, UI-thread callbacks, state/command ordering, detached
targets, snapshots, layout, quotas and GC. A worker fixture verifies A/B input
and F1 dispatch by checking the actual edited string before drawing its result.

Network.Cases starts a separate Python standard-library HTTP server bound only
to 127.0.0.1 on an OS-assigned port. Guest tests validate binary GET bodies, a
POST DataOutputStream/DataInputStream round trip, HEAD, 404 bodies, 302 visibility,
chunked decoding, indexed/named headers, HTTP dates, size quotas and failures.
The server independently records actual method/path/headers/body; URL fragments
and ignored late request properties must not reach it. Delayed requests verify
other Java threads advance, interruption returns InterruptedIOException, and
runtime destruction cancels transport rather than waiting for the server delay.
This does not verify remote Internet services, TLS or physical mobile networks.
Bluetooth.Cases verifies address/UUID normalization, bounded RFCOMM stream and
L2CAP packet behavior, a 100000-byte concurrent transfer, explicit unavailable
operations and provider injection into the core/runtime. Physical radio and
complete JSR-82 compatibility remain unverified and incomplete.
Bluetooth.Data.Cases compares a value/exception grid against preserved Sun
reference classes executed separately on JDK 17. Reference Java code is test-only,
has its original license headers and source hashes, and is not packaged into the
guest JAR or runtime. It also checks exact SDP bytes, malformed prefixes, cycle/
depth limits and GC. Bluetooth.Discovery.Cases uses an injected virtual provider
to exercise successful/empty/failed/cancelled discovery, name refresh, attribute
filtering/copy/population, malformed metadata and array quotas, listener error/
yield recovery, pause and listener-root release. It is not a physical-radio test.

Nokia.Cases checks class/member metadata, fullscreen retention, all nine raw-key
pairs, command rejection, screen visibility transitions, pause/resume, image
immutability, invalid arguments and per-runtime light isolation. A controlled
clock checks flash phases, cancellation, latest-level restoration and the time
limit. A real runtime fixture checks emitted bright/dim frames without repaint.
The Nokia UI continuation passes the four Windows configurations, the complete
JVM/J2ME/font matrix and both frontend build matrices. Portable unit builds are
compile-only. BTBiplanes_s40v3 runs for 40 seconds (751 frames, nonzero PCM,
no uncaught exception); inspected frames show menus and a confirmation overlay,
not verified gameplay. Audio uses the existing MMAPI path, not Nokia Sound.
Absorbed, MobiChess and Tankzors also retain initial frames in no-input probes;
Tankzors waits for its sound choice and reports a caught missing RMS store.
Reports: nokia-ui-check-matrix.log, nokia-ui-frontends.log,
probe-nokia-ui-biplanes-game.tsv and probe-nokia-ui-regression.tsv.

The DirectGraphics continuation adds 66144 pixel/contract checks per Windows
configuration. Compile-only Nokia declarations stay out of guest JARs. Its
test-only JDK helper produces 80 even-odd polygon masks (including self-crossing
and large coordinates) and 80 Java2D source-over cases; the compositor comparison
allows two channel levels of rounding difference, while explicit ARGB cases
assert exact values. Other checks cover all sixteen rotation/flip combinations,
anchors, shared state, encoded image mutability, packed formats/masks, negative
strides, untouched bits, clipping, failure atomicity and metadata. A real Canvas
fixture renders these paths and checks opaque on-screen readback. The inspected
NokiaGraphicsVisual frame is saved under frames/probe-direct-visual.
The final full JVM/J2ME/font checks pass all twelve Windows project/configuration
runs, and both frontend builds pass all eight combinations. Portable unit
compilation passes seven targets, without physical mobile validation.
Bounded scripted ROM runs reach Alien Aggression's Continue title with nonzero
PCM (8 frames/30 seconds), Real Football 2005's title with nonzero PCM (188 frames,
14 seconds, instruction cap), and Atomic Betty's intro (646 frames/30 seconds,
zero PCM). Atomic Betty retained menu/loading content in that 240x320 intro
frame; the screen-size investigation below resolves this observation. These are
not verified playthroughs. Before the Sound continuation, AgeOfEmpires2_S40v3
failed startup on missing com/nokia/mid/sound/SoundListener; that blocker is now
removed as described below.
Reports: direct-final-checks.log, direct-frontends-retry.log,
direct-final-portable.log, probe-direct-games.tsv and probe-direct-input.tsv.

Nokia.Sound.Cases verifies guest contracts and actual PCM across all four Windows
configurations: waveform frequency/duration, exact WAV samples/gain/looping,
stop/resume, OTA default scale/volume, articulation/modifiers/pattern references,
repeat zero/infinite patterns, empty songs, event order, listener errors/yields,
GC root release, pause, channel preemption and concurrent decoder cancellation.
Cross-engine cancellation examples verify MMAPI/Nokia mixing clamps only once.
Command-end regressions cover every possible suffix-byte value, malformed
command-part padding, missing terminators and exact PCM/duration equivalence
when a complete song is followed by bytes or another command stream.
The full JVM/J2ME/font matrix passes twelve runs; both frontend matrices pass
eight builds, and portable unit compilation passes seven targets.
Twenty-eight actual OTA resources from Baseball, Pioo, SpaceImpactIII1 and
SPIDER_MAN2 each produce nonzero PCM via Nokia Sound (two-second WAV artifacts),
without executing those games. This resource check is distinct from gameplay.
With finite scripted input, AgeOfEmpires2_S40v3 reaches mission selection with
nonzero PCM (321 frames/30 seconds), Pioo reaches a pause menu (197 frames,
zero PCM), and SpaceImpactIII1 reaches an initial scene with a ship/enemies and
nonzero PCM (252 frames/30 seconds). These are bounded observations; completed
missions, device-faithful rendering and sustained/manual play remain unverified.
A subsequent Fire-only AgeOfEmpires2_S40v3 scenario enters the tutorial mission
in 45 seconds (482 frames/7782751 instructions, nonzero PCM, no uncaught error).
The inspected frame shows terrain/water, HUD and the cursor-control tutorial
overlay. It establishes entering that mission, not completing its objectives.
Logs: nokia-sound-final-matrix.log, nokia-sound-full-checks.log,
nokia-sound-frontends.log, nokia-sound-portable.log, nokia-sound-resources.tsv,
probe-nokia-sound-games.tsv.

The screen-size continuation diagnoses AtomicBetty.jar using optional caught-
exception tracing: only a caught constructor NumberFormatException appears,
with no paint failures in the observed run. Its original menu and intro PNGs
are 176x208. Repeating the same finite input at 176x208 produces a clean intro
without residual menu/loading pixels (645 frames/30 seconds, zero PCM, no
uncaught error). The 240x320 run leaves areas outside these fixed-size images
unpainted. This version should use the 176x208 preset in Java ME video settings.
The result does not establish a complete level or audio compatibility; the
scenario chooses sound off. Further input runs stop at a training prompt or
exit through notifyDestroyed, so they do not establish gameplay.
Phone.Profile.Cases checks size parsing, all twelve preset values, legacy/custom
INI preservation, invalid-preset fallback, persistence and actual worker frame
dimensions/corner pixels after start/reset. JVMChecks also checks default-off
exception tracing, the 64-entry ring and omissions, guest behavior/GC, pure drain
and isolation between VMs. Full checks pass twelve Windows combinations, both
frontends pass eight builds, and portable unit compilation passes seven targets.
The new settings row uses the existing declarative renderer; its appearance
and physical mobile behavior have not been visually checked.
Reports: phone-full-checks.log, phone-frontends.log, phone-portable.log,
phone-profile-matrix.log, probe-atomic-before.tsv, probe-atomic-native-size.tsv.

## Next Java ME milestones

The Runtime continuation resolved Tankzors' missing java/lang/Runtime. The next
investigation measured the single-character reader path rather than assuming
it caused the loading delay: the controlled text workload takes roughly 0.1 s
in the bare VM. The unconditional host sleep was the major throughput limit.
On the same 494590-instruction J2ME workload, three samples of the old host policy
took 3873-3889 ms and 248 sleeps; the runnable-work policy took 123-126 ms and
one sleep, with the same independently checked JDK checksum. This is a specific
Windows benchmark, not an across-games performance multiplier.

With finite input and loading pauses, Tankzors reached its main menu in a
20-second run (240 frames) and an actual level in a 40-second run (650 frames,
4179621 instructions, no uncaught exception). The inspected final frame shows
the tank, terrain, obstacles and HUD. Sound was disabled in this input sequence.
Repeated keys during transitions can still hit a null guest receiver; exact
transition-event and device compatibility remain unverified.
Absorbed reached its menu with nonzero PCM in a 12-second run after the scheduling
change. Its preceding 45-second run had verified initial gameplay (737 frames).
These are bounded scripted observations, not completed levels or playthroughs.
Reports: runnable-benchmark.tsv, probe-runnable-tankzors-choice.tsv,
probe-runnable-tankzors-play.tsv, probe-runnable-absorbed.tsv. Streaming media,
broader device validation and remaining compatibility work are still pending.

The Character follow-up removes Snake.jar's BitmapFont constructor failure.
The same default 240x320 profile now reaches its Snake 0.91 menu (43 frames in
10 seconds); a finite Fire/arrow sequence then reaches an actual moving game
field (41 frames/327315 instructions in 9.314 seconds), with no traced or
uncaught exception. This is initial gameplay, not a complete session or audio
validation. Hoovies reaches language selection, Angry Birds the Rovio startup
screen, and Alice in Wonderland its title screen with nonzero PCM in separate
seven-second observations.

A new startup sample covers the 104 JARs whose constant pools reference
Character, with no input, 240x320 and a one-second/one-million-instruction bound
per JAR: 76 publish frames, 10 finish the observation without a frame/uncaught
error, 17 report uncaught errors and one is rejected at suite loading. These
counts do not establish working games. The sample identifies remaining
Math.min/max(long), Boolean, Calendar, DateField, MIDlet.resumeRequest,
wireless messaging and M3G/Mascot APIs, plus several guest null failures.
VansSkateAndSlam's profile rejection was a parser issue with the manifest value
`MIDP-2.0  `; the descriptor follow-up now removes it.
Artifacts: character-corpus/startup.tsv and SUMMARY.json,
probe-character-snake-menu.tsv, probe-character-snake-play.tsv and
probe-character-games.tsv under codex-work/jvm-j2me, with frames/throw traces.

The Math/Boolean/descriptor follow-up removes five observed min/max(long)
blockers. Five-second no-input runs now show the Freestyle Moto-X II startup
screen in both tested variants (151/153 frames); Diamond Twister 2 reaches a
Gameloft loading frame. Green Farm still shows a white frame at the instruction
bound. Fast and Furious advances to missing m3g/Object3D and remains blocked.
Simon now reaches its main menu after Boolean support (70 frames in 8 seconds).
One Fire input reaches its Level 1 / YOUR TURN game field (152 frames and
15002172 instructions in 10.596 seconds, stopping at the instruction bound).
The game catches an unsupported audio/mpeg MediaException and produces no PCM;
neither a completed round nor audio compatibility is established.
VansSkateAndSlam now passes suite loading and shows its trademark screen before
reaching the instruction bound (4 frames, 2.843 seconds); its caught missing-RMS
default is retained in diagnostics. These are startup observations, not new
gameplay or completed-game claims. Reports: probe-math-games.tsv and
probe-boolean-profile-games.tsv, with inspected PNGs and exception traces.
The Simon interaction is recorded separately in probe-simon-play.tsv.

The Billy text investigation identifies a geometry mismatch rather than a
renderer defect: its196x70 FONT atlas holds7x14 cells, but its guest code selects
9x15 cells when width is at least240. At176x208 the same unmodified JAR displays
readable Main menu / Play / OK / Exit and produces nonzero PCM. The default
240x320 and global device settings are unchanged; choose the matching geometry
for this JAR. Disassembly, original atlas and observed frames are under
`codex-work/jvm-j2me/billy-text/`. The initial240x320 corruption noted below is
retained as historical evidence, not an unresolved renderer conclusion.

The lifecycle/Calendar follow-up removes the missing resumeRequest and Calendar
startup failures in BillyTheKid2 and both Total Overdose variants. Billy reaches
its title artwork, with visibly corrupted lower text/softkeys and silent PCM.
Both Total variants reach the main menu and, with repeated softkey/Fire/Right
input, the first level with the player/HUD and Tommy tutorial visible. Each
30-second level observation publishes 378 frames and nonzero PCM without an
uncaught failure. The tutorial requests a rapid double tap, which the probe
sequence does not exercise; movement beyond it, level completion, sound quality
and sustained gameplay remain unverified. Reports and inspected frames:
codex-work/jvm-j2me/lifecycle-calendar-games/.

The DateField follow-up removed Cars' missing DateField class. The subsequent
WMA addition removes the next missing TextMessage/startApp failure. Its20-second
startup now publishes3 frames and shows its own Data connection unavailable
screen: VservManager catches HTTP DNS error12007 resolving its ad service.
Cars gameplay remains unverified. Tibia also passes its old missing Message
failure and reaches the main menu; a20-second '1',Fire input run reaches its
New game form with Name/Password, World, Vocation and Gender fields (38 frames).
No login, character creation, server connection or gameplay is established;
startup traces retain caught RMS and missing Presents.png fallback errors.
Reports, inspected frames and exceptions: messaging-games/ in the working folder.
The DateField diagnostic form separately passes keypad/text edits, monitor and
callback checks and shows a wrapped date/time editor at96x65 with the selected
minute component visible. Reports: datefield-games/ under the working folder.

1. Complete the commonly used CLDC library: additional legacy charsets,
   remaining byte-stream operations, exact floating-point text,
   remaining String operations, fuller numeric wrappers
   and remaining exception types. CLDC Class loading/creation APIs,
   mutable UTF-16 buffer operations and the initial
   byte/data stream, array charset conversion, resource I/O and Random
   implementations are now present.
2. Refine Graphics compatibility, add wider font coverage and complete display
   event ordering; expand from initial real frames to verified game
   interaction and sustained gameplay.
3. Add CustomItem and complete Form/editable-control coverage, including
   frontend Unicode/IME input and mobile controls. Finish RMS cross-process notifications/save
   management and expand MMAPI beyond its
   WAV/MIDI/tone foundation, then vendor extensions evidenced by the ROM inventory. Expand the startup corpus
   after each milestone and add regression checks for each verified behavior.
   Extend buffered HTTP to streaming and HTTPS/security information, then GCF
   sockets/datagrams/files. Complete the JSR-82 translator against the common
   IBluetoothProvider contract and add native backends beyond Windows RFCOMM; keep transport,
   discovery and permissions out of the shared VM.
4. Measure sustained gameplay on Windows, then build and validate mobile targets.
   Add state snapshots only after the guest heap/thread/display model stabilizes.

Primary references: [JVM class format](https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-4.html),
[instruction semantics](https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-6.html),
[CLDC 1.1](https://jcp.org/en/jsr/detail?id=139),
[MIDP 2.0](https://jcp.org/en/jsr/detail?id=118),
[Thread API](https://docs.oracle.com/javase/7/docs/api/java/lang/Thread.html),
[monitor/wait API](https://docs.oracle.com/javase/7/docs/api/java/lang/Object.html),
[class initialization](https://docs.oracle.com/javase/specs/jls/se7/html/jls-12.html#jls-12.4.2).

Verification references: [JVMS type checking/inference](https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-4.html#jvms-4.10),
[CLDC typechecker appendix](https://docs.oracle.com/javame/8.0/api/cldc/api/Appendix1-verifier.pdf).
Linkage references: [JVMS resolution/access/overriding](https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-5.html#jvms-5.4.3),
[protected receiver verification](https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-4.html#jvms-4.10.1.8).
Library references: [CLDC Random](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/util/Random.html),
[CLDC Runtime](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Runtime.html),
[CLDC StringBuffer](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/StringBuffer.html),
[CLDC DataInputStream](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/io/DataInputStream.html),
[CLDC Class resource API](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Class.html).
Charset references: [CLDC String byte conversions](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/String.html),
[standard charset/BOM semantics](https://docs.oracle.com/javase/7/docs/api/java/nio/charset/Charset.html).
Writer references: [CLDC Writer](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/io/Writer.html),
[CLDC OutputStreamWriter](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/io/OutputStreamWriter.html).
Character references: [CLDC Character](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Character.html),
[CLDC String case rules](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/String.html),
[Unicode 3.0 data](https://www.unicode.org/Public/3.0-Update/UnicodeData-3.0.0.txt).
Math/Boolean references: [CLDC Math](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Math.html),
[CLDC Boolean](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Boolean.html).
Descriptor reference: [MIDP application attributes](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/midlet/package-summary.html).
Rendering references: [MIDP Image/PNG requirements](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Image.html),
[MIDP Graphics](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Graphics.html),
[MIDP Font](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Font.html),
[PNG specification](https://www.w3.org/TR/2003/REC-PNG-20031110/).
Game references: [GameCanvas](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/game/GameCanvas.html),
[Sprite](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/game/Sprite.html),
[TiledLayer](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/game/TiledLayer.html),
[LayerManager](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/game/LayerManager.html),
[Canvas event delivery/serviceRepaints](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Canvas.html).
Media references: [Player lifecycle/events](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/media/Player.html),
[Manager stream/content/tone APIs](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/media/Manager.html),
[PlayerListener](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/media/PlayerListener.html),
[VolumeControl](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/media/control/VolumeControl.html).

RMS references: [RecordStore persistence/identity/authorization](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/rms/RecordStore.html),
[RecordEnumeration](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/rms/RecordEnumeration.html),
[RecordListener](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/rms/RecordListener.html),
[Windows LockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex),
[POSIX flock](https://man7.org/linux/man-pages/man2/flock.2.html).

LCDUI references: [Displayable](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Displayable.html),
[Command](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Command.html),
[Canvas visibility/normal/fullscreen modes](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Canvas.html),
[Display serial callbacks](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Display.html),
[Choice](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Choice.html),
[List](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/List.html),
[Ticker](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Ticker.html),
[GameCanvas buffer and flush](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/game/GameCanvas.html).

Form/editing references: [Form](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Form.html),
[TextField](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/TextField.html),
[TextBox](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/TextBox.html),
[Item](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Item.html).

Connection references: [Connector](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/io/Connector.html),
[Connection stream lifetime](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/io/Connection.html),
[HTTP states and output commitment](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/io/HttpConnection.html),
[MIDlet platform requests and permissions](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/midlet/MIDlet.html).
Bluetooth references: [Motorola JSR-82 specification, preserved PDF](https://www.ebixio.com/online_docs/btapi/JSR82-spec_1.0a.pdf),
[Oracle client/server and service registration guide](https://www.oracle.com/technical-resources/articles/javame/bluetooth-wireless-technology-part2.html),
[JCP PSM amendment](https://jcp.org/aboutJava/communityprocess/maintenance/jsr082/MR4changes.html),
[Oracle DiscoveryAgent API](https://docs.oracle.com/javame/config/cldc/opt-pkgs/api/bluetooth/jsr082/javax/bluetooth/DiscoveryAgent.html),
[RIM-authored DiscoveryAgent detailed contract, preserved SDK documentation](https://nikita36078.github.io/J2ME_Docs/docs/BlackBerry_API_7_1_0/javax/bluetooth/DiscoveryAgent.html),
[SDP UUID representation](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-62/out/en/host/service-discovery-protocol--sdp--specification.html),
[L2CAP MTU and packet semantics](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v7.0/out/en/host/logicallinkcontrol-andadaptationprotocol-l2cap--specification.html).
Windows backend references: [Bluetooth Winsock programming](https://learn.microsoft.com/en-us/windows/win32/bluetooth/bluetooth-programming-with-windows-sockets),
[native SDP registration](https://learn.microsoft.com/en-us/windows/win32/bluetooth/bluetooth-and-wsasetservice),
[BTH_SET_SERVICE record/handle layout](https://learn.microsoft.com/en-us/windows/win32/api/ws2bth/ns-ws2bth-bth_set_service),
[socket security options](https://learn.microsoft.com/en-us/windows/win32/bluetooth/bluetooth-and-socket-options),
[overlapped I/O and buffer lifetime](https://learn.microsoft.com/en-us/windows/win32/winsock/overlapped-i-o-2),
[Windows Bluetooth driver stack and L2CAP profile drivers](https://learn.microsoft.com/en-us/windows-hardware/drivers/bluetooth/bluetooth-driver-stack).

Timer/date references: [MIDP Timer](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/java/util/Timer.html),
[TimerTask](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/java/util/TimerTask.html),
[CLDC Date](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/util/Date.html),
[Calendar](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/util/Calendar.html),
[TimeZone](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/util/TimeZone.html).

Collection references: [CLDC Vector](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/util/Vector.html),
[Enumeration](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/util/Enumeration.html),
[Stack](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/util/Stack.html).

Integer reference: [CLDC Integer](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Integer.html).
Long reference: [CLDC 1.1 Long](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Long.html).
The Long oracle checks70521 parsing cases (including every BMP code unit against
Unicode3.0 data),64493 radix-format cases and1573 independently evaluated hash/
IEEE conversion values, including signed limits and rounding midpoints. JDK
arithmetic/format/conversions supply reference values; parsing expectations adjust
the leading-plus and Unicode-version differences required by CLDC. Resource chunks
stay inside the VM's normal array limit. Declaration checks inspect the real Long
class/field flags; guest comparisons run through GC and the normal bytecode engine.
J2ME.Media links `source/cores/j2me/J2ME.SoundFont.res`, with the unmodified
shared TimGM6mb bank and complete license as named RCDATA resources. Its source
is `J2ME.SoundFont.rc`; rebuild from that directory with
`brcc32 '-foJ2ME.SoundFont.res' J2ME.SoundFont.rc` after changing either original asset
in `assets/music/soundfonts`. The resource follows the existing firmware-resource
build convention. GUI, terminal and probes all link the same resource; no extra
SF2 copy target is needed. Optional external SF2 files and explicit custom bank
selection still take precedence. The shared MIDI decoder's
`SetDefaultMidiSoundFontResource` registers a lazy fallback without loading data or
replacing a selected bank. Applications that do not link J2ME retain their existing
external-file MIDI behavior.

Existing TimGM6mb and GeneralUser GS both cover all128 GM program IDs and the
standard drum bank; no new bank was required for the tested games. Four Windows
configurations verify exact embedded bank/license bytes, and render8 real MIDI
resources twice (with and without a beside-EXE SF2). Corresponding PCM is
byte-identical. Portable units compile for7 non-Windows targets; linking/resource
lookup on mobile devices and reference-phone timbre remain unverified. This does
not establish complete SoundFont-feature conformance. See
`codex-work/jvm-j2me/soundfont-resource/summary.json`.
RMS wait references: [queued LockFileEx behavior](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex),
[cancellation and OVERLAPPED lifetime](https://learn.microsoft.com/en-us/windows/win32/fileio/canceling-pending-i-o-operations).

Siemens references (vendor-authored API documentation mirrored for preservation):
[MelodyComposer](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/MelodyComposer.html),
[Melody](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/Melody.html),
[Sound](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/Sound.html),
[Light](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/Light.html),
[Vibrator](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/Vibrator.html),
[constant values](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/constant-values.html).
The preserved contract extracts/blob IDs are in
`codex-work/jvm-j2me/siemens/reference/api-contract.json`.

`build-siemens.ps1` builds/runs the focused `J2MEChecks --siemens-game SiemensGame.jar`
checks in all4 Windows configurations. The guest JAR contains no SDK API classes.
Checks inspect all83 actual field values/flags and static Melody.stop, copied
constructor data and score snapshots,14 independently calculated Python Fraction
durations/58 measured pitches, finite/
nested/marked/infinite repeats, independent melody/tone mixing, pause, GC churn and
limits. Deterministic model checks measure motor duty/expiry/strength, saturation,
consumed samples, backlight/flash timing; real worker checks exercise rumble output
and normal/rapid Pause/Resume cancellation. A guest-rendered acknowledgment proves
that a post-cancellation command reached the worker before accepting zero output.
Measured PCM validates this virtual
model, not the undocumented handset calibration or physical actuator performance.

Siemens graphics references (preserved vendor-authored documentation):
[ExtendedImage](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/ExtendedImage.html),
[GraphicObject](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/GraphicObject.html),
[GraphicObjectManager](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/GraphicObjectManager.html),
[Sprite](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/Sprite.html),
[TiledBackground](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/game/TiledBackground.html),
[UI Image](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/ui/Image.html),
[standard Image extension](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/javax/microedition/lcdui/Image.html).
Contract extracts and Git blob IDs are in
`codex-work/jvm-j2me/siemens-graphics/reference/api-contract.json`.
`build-siemens-graphics.ps1` runs `J2MEChecks --siemens-graphics SiemensGraphics.jar`
in all4 Windows configurations. A separate Java SE reference generator uses JDK
indexed rasters for96 packed-image cases, Graphics2D/TexturePaint for128 masked
scene cases (all3 constructors, heights1/5/7/8/9/13/16 and extreme coordinates),
and BigInteger arithmetic for8192 collision cases. Guest tests compare actual
ARGB/code bytes, constructor input snapshots, live map edits, errors/atomicity,
scene image aliases, RGB332 values, wrapper/copy identities, reflections, PNG
loading/scaling and GC. Two direct-screen blits compare independent JDK pixels
without invoking Canvas.paint; an offscreen blit does not publish a frame.
Diagnostic JARs exclude Java/Javax/Siemens SDK implementations. These regressions
validate the stated virtual model, not unspecified handset semantics. Broader
bounded JAR scenarios and remaining blockers are recorded in
`codex-work/jvm-j2me/siemens-graphics/REPORT.txt`.

JAR resource references:
[MIDP resource-name rules](https://nikita36078.github.io/J2ME_Docs/docs/midp-2.0/java/lang/package-summary.html),
[CLDC Class resource lookup](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Class.html),
[preserved Siemens Connector](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/javax/microedition/io/Connector.html),
[Connection stream ownership](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/javax/microedition/io/Connection.html).
`build-resources.ps1` runs the focused diagnostics in all4 Windows configurations.
The independent Java SE generator applies MIDP's string rewrites before JDK JAR
lookup; unmodified Java SE lookup does not provide these MIDP rewrites. Guest
tests compare1048 path cases (148 found), typed JDK DataOutputStream data and a
50003-byte read/hash, stream ownership/positions/mark/close/EOF/errors,320-handle
churn, an unsupported ZIP-method IOException, array-quota recovery, GC and pause.
A separate plain Java host proves that MIDP classfile restrictions do not leak
into the reusable library. Diagnostic JARs exclude SDK implementations. The
current graphics oracle additionally covers32 scenes with an absent sprite mask.
It also compares256 packed-image blits against JDK AlphaComposite.Src, including
negative/partial/offscreen rectangles, both bit depths and extreme coordinates.
Bounded real-JAR evidence and unresolved startup/input cases are recorded in
`codex-work/jvm-j2me/resources/REPORT.txt` and `summary.json`.

Siemens `com.siemens.mp.color_game` uses the shared game renderer and key/buffer
engine through a separate class hierarchy. The preserved 2003 API has its own
contracts: Sprite provides bounding-rectangle collisions for both values of
`pixelLevel`, no transform/reference-pixel API, and TiledLayer limits static and
animated tiles to 32767. Layer exposes protected image/copy methods and bounded
width/height changes; rendering clips to these bounds and restores Graphics state
on errors. LayerManager defaults to a screen-sized view and invokes guest paint
methods through a yielding, exception-safe snapshot. MIDP 2.0 retains its own
transforms, pixel collisions and unlimited default manager view.

Protected image replacement preserves base bounds and frame definitions; an
image too small for a derived frame/tile raises Java IllegalArgumentException
when painted. `copyAllLayerVariables` copies base state from receiver to argument,
including image, original size caps and the protected NativeMemoryTable reference.
Replacing a Sprite image or tile set establishes new frame/grid size caps.
NativeMemoryTable is a guest compatibility reference, not a host pointer; the
undocumented `removeLayer(memory, layer)` delegates to `remove(layer)`. Invisible
sprites do not collide in this virtual implementation. These unspecified details
remain unverified on Siemens hardware.

References: preserved Siemens
[Layer](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/color_game/Layer.html),
[Sprite](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/color_game/Sprite.html),
[TiledLayer](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/color_game/TiledLayer.html),
[LayerManager](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/color_game/LayerManager.html),
[GameCanvas](https://nikita36078.github.io/J2ME_Docs/docs/Siemens_API/com/siemens/mp/color_game/GameCanvas.html).
Blob IDs, signatures and explicit virtual policies are recorded in
`codex-work/jvm-j2me/siemens-color/reference.json`.
`build-siemens-color.ps1` runs focused checks in all four Windows configurations:
192 independent JDK Graphics2D scenes (132 nonblank, 1060 changed pixels),
4096 BigInteger rectangle cases, the exact tile-index limits, allocation recovery,
protected API metadata, clipped rendering, yielding/throwing paint, snapshot GC,
GameCanvas key latches/suppression and foreground/background rendering. The guest
JAR excludes all SDK classes. Real-game results remain bounded launch/menu checks;
missing Siemens Media and ConnectionListener are separate blockers.

`J2MEProbe` now accepts `--wall-time` to remove its default instruction cap and
`--input-after-frame` to delay the input sequence until the first published frame.
Per-JAR input TSVs record calls to Runtime.KeyEvent with time, instruction count,
runtime state and observed frame count; they do not alone prove guest processing.
One-second PNG samples supplement the first/last frames, and diagnostics identify
the exit budget. Wall time is a soft bound: synchronous native calls may overrun it.
For menu stages that need different pauses, `--actions <UTF-8 TSV file>` selects
a scheduled input plan instead of the positional key sequence. Its three columns
are `delay_ms`, `action` (`press`, `release`, `text`) and `value` (Java key code or
text). Each delay runs from the previous actual dispatch, with the initial delay
starting at the first frame when `--input-after-frame` is set. Overdue events do
not burst. Plans are limited to 1024 events, 60 seconds of total delays and 256 KiB;
text events call the ordinary runtime text-input API. The trace records dispatch,
so inspect game frames before claiming the game accepted a command. The probe
retains the last published frame in memory and encodes its final PNG once.
`codex-work/jvm-j2me/verify_probe_actions.py` checks parsing, event order, timing
and suppression of the legacy sequence in all four Windows configurations.
The existing legacy compatibility policy services display/input while startApp is
still running; `Starting` by itself is not proof of an input stall. The standard
MIDP lifecycle/display contract expects startApp to return promptly, so this is a
compatibility policy, not strict lifecycle conformance. The existing LegacyMIDlet
fixture verifies keys, pause/resume, serialized UI callbacks and GC in that state.
See `codex-work/jvm-j2me/startup-input/REPORT.txt` for the repeated real-game runs.

Nokia references (Nokia-authored API documentation mirrored for preservation):
[FullCanvas](https://nikita36078.github.io/J2ME_Docs/docs/Nokia_UI_API_1_1/com/nokia/mid/ui/FullCanvas.html),
[DeviceControl](https://nikita36078.github.io/J2ME_Docs/docs/Nokia_UI_API_1_1/com/nokia/mid/ui/DeviceControl.html).
[DirectGraphics](https://nikita36078.github.io/J2ME_Docs/docs/Nokia_UI_API_1_1/com/nokia/mid/ui/DirectGraphics.html),
[DirectUtils](https://nikita36078.github.io/J2ME_Docs/docs/Nokia_UI_API_1_1/com/nokia/mid/ui/DirectUtils.html).
[Sound](https://nikita36078.github.io/J2ME_Docs/docs/Nokia_UI_API_1_1/com/nokia/mid/sound/Sound.html),
[SoundListener](https://nikita36078.github.io/J2ME_Docs/docs/Nokia_UI_API_1_1/com/nokia/mid/sound/SoundListener.html),
[Nokia Smart Messaging 3.0, section 3.6](https://customer.intele.no/files/Smart_Messaging_Specification_rev_3_0_0.pdf)
([preserved text mirror](https://www.scribd.com/document/655577912/sms3-0-0)).

Hashtable/wrapper references: [CLDC Hashtable](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/util/Hashtable.html),
[Byte](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Byte.html),
[Short](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Short.html).

DateField reference: [MIDP DateField](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/DateField.html).
DateField tests use744 JDK Calendar calculations for expected normalization;
separate guest checks cover MIDP modes/nulls/copies/errors, inherited Item APIs,
custom yielding/throwing TimeZone and Date methods, monitor exclusion during
callbacks, UI edits/notifications/commands and detached-object collection.
The JDK oracle supplies calendar arithmetic, not a JDK DateField widget or a
certification/conformance claim. `datefield-form.png` records the software form.

Messaging references: [JSR-120 WMA1.1 maintenance specification](https://jcp.org/aboutJava/communityprocess/maintenance/jsr120/Diffs.pdf),
[3GPP GSM default/extension alphabets, TS23.038](https://www.etsi.org/deliver/etsi_ts/123000_123099/123038/17.00.00_60/ts_123038v170000p.pdf),
[SMS concatenation headers, TS23.040](https://www.etsi.org/deliver/etsi_ts/123000_123099/123040/05.03.00_60/ts_123040v050300p.pdf).
The independent oracle checks all65536 UTF-16 code units against the alphabet
and432 boundary cases derived from140-octet payload budgets and UDH bit lengths.
It includes the currency sign, extension escapes, port0, UCS-2 and the255-part
protocol boundary. These are arithmetic and runtime regressions, not WMA
certification or carrier interoperability tests.

### M3G geometry foundation

The J2ME host installs native `Transform`, `VertexArray`, `VertexBuffer`,
`IndexBuffer`, `TriangleStripArray`, `Node`, `Group`, `Camera`, `World` and `Light`
objects. Matrices use row-major storage
and column vectors. Vertex buffers retain shared attributes, copy scale/bias
values and validate component types and vertex counts before replacing state.
Two texture-coordinate slots are available. Triangle-strip expansion preserves
winding across odd/even triangles and restarts parity for each strip.

Geometry is stored in the guest heap, including internal vertex/index arrays,
so ordinary GC and snapshots preserve it. Non-node duplication copies internal
storage and scalar state while retaining shared Object3D attributes and user
objects. Reference enumeration includes duplicate attribute references and
excludes application user objects; `find` follows those Object3D references.

The abstract `Transformable` layer implements independent translation, scale,
orientation and general matrix components. Its composite is `T R S M`;
`preRotate` and `postRotate` change orientation in opposite multiplication
orders. General matrices are copied, with null resetting that component to
identity. Orientation queries reconstruct an equivalent angle/axis, including
half turns. Native subclasses inherit identity defaults without heap allocations
for unused components. There is no guest-accessible constructor. The fixture
uses an internally allocated test subclass to exercise this layer before scene
nodes and textures exist. Its scalar/matrix fields support ordinary snapshots.

Groups maintain bidirectional parent/child links, prohibit cycles and multiple
parents, and detach children without modifying absent children. Relative node
transforms follow the path through the lowest common ancestor, excluding that
ancestor's own transformation. Node matrices must be affine. Branch duplication
rebuilds the descendant hierarchy and its parent links; parent references are
excluded from Object3D enumeration/find. Camera supports copied generic matrices,
perspective/parallel parameters, reversed clipping planes and deferred errors for
empty view volumes. Camera and hierarchy state use ordinary guest heap storage.

`Mesh` retains shared vertex/index/appearance objects while copying constructor
array containers into independent slots. Submesh index errors are deferred to
future rendering/picking, while constructors reject null/empty index buffers.
Mesh duplication keeps shared geometry and appearances; replacing one appearance
slot in a duplicate does not modify the source. Object3D traversal includes these
references, with duplicates, without treating them as child nodes.

`Appearance` retains its component objects, two texture slots and a layer in
[-63,63]. `Material` stores the four lighting colors, validated color masks,
shininess and vertex color tracking. Only diffuse color retains alpha in getters.
These objects have working state/copy/GC/snapshot behavior and now drive native
vertex lighting through `J2ME.M3G.Lighting`.

`World` retains active camera/background references separately from child links.
World nodes, including user subclasses, cannot be added as children. Duplication
remaps the active camera when it is in the copied subtree, retaining external
camera references otherwise. Setting a null active camera raises the documented
exception; a newly created World still starts with no active camera.
`Light` stores its mode, RGB color, intensity (including negative intensity),
attenuation and spot parameters with API validation. Light state is preserved
by duplication and snapshots and is read by the lighting stage on each draw.
`Background` stores color/image, crop, BORDER/REPEAT modes and independent color
and depth clear flags. Clearing maps the source crop by nearest pixel-center
sampling to the captured viewport/clip, including repeated negative offsets,
zero crops, mutable images and aliased source/target storage. RGB/RGBA format
compatibility is validated before clearing. State and image references survive
duplication, GC and snapshots.
`Fog` supports LINEAR and EXPONENTIAL modes, RGB color, density and near/far
planes. The rasterizer interpolates camera distance with perspective correction,
applies fog to RGB before compositing and preserves alpha. Equal linear planes
have undefined API results; this implementation chooses unchanged source color.

The `Graphics3D` renderer draws lit or unlit triangle strips with flat/smooth colors and textures
into MIDP Graphics targets, including Canvas and mutable Image, and mutable RGB
or RGBA `Image2D` targets. It clips in homogeneous camera space before dividing
by W, performs configured face culling/winding, half-open pixel coverage, alpha
testing, five compositing modes, channel/depth masks and depth testing/writing,
and captures Graphics clipping
and origin at bind time. Camera/viewport/depth-range state and a bound target's
depth array are guest heap state and survive snapshots. Release discards depth.
The partial implementation continues to leave the package version unadvertised.

`render(World)` uses the active camera's hierarchy transform, clears the World
background and updates current camera/light state. `render(Node,Transform)`
ignores root/ancestor transforms and attributes, retaining the current camera,
lights and target contents. Descendant transforms, rendering enables, multiplied
alpha factors, local mesh/camera scope masks, null appearances, ascending layers
and opaque-before-blended ordering within layers are respected. Traversal uses
an iterative stack. The current light array supports add/set/get/reset, nullable
slots, copied transforms and snapshots.
Camera transforms are validated for invertibility when assigned.

Material lighting combines emissive, ambient, diffuse and specular terms, with
no global ambient term. Ambient lights affect only the ambient material;
directional/omni/spot lights contribute diffuse/specular terms. Scope masks,
rendering enables, copied world-to-camera light transforms, negative intensity,
distance attenuation, spotlight cutoff/exponent and local viewer highlights
are respected. Normal components use the signed mapping `(2n+1)/(2^bits-1)`,
then inverse-transpose model-view transformation and normalization. The divisor
cancels when normalizing; the bias does not. Vertex color tracking replaces
ambient/diffuse colors, with alpha taken from diffuse or the tracked color and
multiplied by effective node alpha. Front/back colors are calculated separately
for two-sided lighting, and flat shading retains the original provoking vertex
through clipping. Missing normals and singular normal transforms have undefined
API results; deterministic defaults are used without rejecting rasterizable
geometry. Native loops observe VM cancellation. State is rebuilt from guest
objects after snapshot restoration, without changing the snapshot format.

`Image2D` implements all five pixel formats, byte/palette/MIDP image input,
mutable rectangle updates, independent pixel storage on duplicate and guest
heap snapshots. Pixel conversion uses the package rules, including the distinct
RGB-to-alpha treatment for mutable MIDP sources. Missing palette entries use
opaque white; their contents are unspecified by the API. `Texture2D` validates
power-of-two image dimensions (up to 1024), wrapping/filtering/blending state,
retains its image reference and uses the existing Transformable components.
Two texture units support all five image formats and texture blending modes,
CLAMP/REPEAT, nearest/bilinear base-level filtering and homogeneous projective
STQ interpolation. Three-component coordinates and Texture2D transforms are
applied before projection. Filtering between mip levels remains an unimplemented
quality hint. Flat/smooth RGB/RGBA vertex colors are unsigned, and texture color
is fogged before framebuffer compositing. `CompositingMode` and `PolygonMode` state is
now connected to the renderer, including two-sided lighting and local viewer
highlights. Depth offset units use an increment of 2^-24.

`Sprite3D` implements scaled/unscaled state, shared image/appearance references,
signed crop rectangles, independent duplication and snapshot restoration. Crop
dimensions are limited to 1024 in absolute value; setImage resets the crop, and
initial crops are clamped to that limit. Source images may be non-power-of-two
and mutable. The renderer projects the sprite origin at constant depth and
computes scaled dimensions from the documented camera-space reference-point
distances. Unscaled sprites retain an integral pixel footprint during subpixel
movement. Negative crop dimensions reflect the image without moving the source
rectangle; out-of-image samples are discarded before depth writes. Only layer,
Fog and CompositingMode are used from Appearance. Material, textures and polygon
attributes are ignored. Effective node alpha is applied directly to the image
alpha to avoid premature quantization. Immediate, grouped and World rendering
share scope/enables, sorting, viewport clipping, depth and composition behavior.

`J2ME.M3G.Format` reads bounded M3G sections and primitive values, validates
Adler-32/zlib lengths, UTF-8, Float32 and header/external-section sequencing.
Four Windows configurations test malformed inputs and all eight real NFS model
containers. The separate Loader interprets object payloads after these checks.

`J2ME.M3G.Loader` now deserializes Appearance, Camera, CompositingMode, PolygonMode,
Group, Image2D, TriangleStripArray, Light, Material, Mesh, Texture2D, VertexArray,
VertexBuffer, World, Background, Fog and Sprite3D (type 18). It follows typed backward references, decodes raw/delta
vertices and index encodings, builds parent links through the native APIs, and
returns only root objects. Immediate construction errors become IOException;
deferred rendering validation stays deferred. User parameters become ordinary
guest Hashtables with Integer keys and byte[] values, using a reusable native
factory in Java.Hashtable. Duplicate IDs are rejected.

Named resources and relative dependencies are resolved case-sensitively within
the JAR; explicit resource: URIs also work from byte arrays. Per-load caching
preserves shared external references, cycles/depth/byte limits are checked and
all temporary roots are released on success or error. HTTP and other download
protocols remain unimplemented. PNG input uses the shared native decoder, with
the Image2D format selected by PNG color type and tRNS; byte-array offsets can
select packed M3G/PNG assets followed by other data. The first root of an external
M3G file is retained, as specified by the format.

All eight real NFS models now load as one Group/Mesh/World root each with their
expected reachable graph sizes. NFS's 2D image blocker is fixed: splash1.png is
GIF and menucar.png is JPEG despite their names, and MIDP Image now recognizes
the formats by content. The current loader-game trace passes Background setup
and the sound prompt. A 30-second input probe now renders a textured car/road
scene and produces audio, with no missing world-render method or duplicate-ID
cast fault. The JAR lacks optional racecharacter.png, which the game catches.
This is bounded scene execution, not a full playthrough or compatibility claim.

`Media.Image.Decode` shares PNG/GIF/JPEG bitmap decoding with J2ME. GIF87a/89a
supports global/local palettes, transparent indices, offsets on the logical
screen, interlacing and bounded 12-bit LZW (including a full dictionary without
Clear). Static Image uses the first frame; later animation frames are checked
structurally and are not animated. Plain Text extensions remain unsupported.
`Media.Image.JPEG` shares RetroMul's original PSP IDCT with the PSP adapter and
adds bounded sequential 8-bit grayscale, YCbCr/RGB, quantization/Huffman tables,
interleaved and separate scans, restart markers, and centered chroma upsampling.
Progressive/lossless/arithmetic/CMYK JPEG remain unsupported. The PSP adapter
keeps its existing 4:2:0 policy and error mapping. Valid 4:2:0 decoded planes are
compared byte-for-byte against the prior native implementation, alongside the
full PSP regression suite.

Image tests use 42 independently decoded JDK ImageIO files, including all five
GIF/JPEG resources disguised as PNG in this NFS JAR. GIF pixels match exactly;
the largest JPEG difference in these fixtures is 5/255 on a channel. Explicit
fixtures also cover logical screen offsets, first-frame selection, LZW KwKwK,
deferred Clear, multiple JPEG scans, Adobe RGB and restarts. Truncation, mutation
and quotas are checked, and MIDP resource/byte[]/stream overloads preserve the
required error classes, immutable pixels, GC and snapshot behavior. This is a
bounded implementation check, not a JPEG/GIF conformance certification.
Format references: [GIF89a](https://www.w3.org/Graphics/GIF/spec-gif89a.txt),
[ITU T.81](https://www.w3.org/Graphics/JPEG/itu-t81.pdf), and
[MIDP Image](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/lcdui/Image.html).

The raster oracle uses exact rational sample tests on the original plane for
64 orthographic scenes and independent exact ray/triangle intersections for
32 perspective scenes. These compare 24576 pixels in all four Windows builds.
Separate tests cover depth, clipping/origin, a bound-frame snapshot and the real
MIDlet/Canvas publication path. Pixel artifacts are in the M3G check build folders.
An additional 49 cases compare 436 image/conversion/compositing/culling pixels
both before and after GC/snapshot restoration. Full-screen two-triangle quads
also check that a shared edge is blended once, without holes or overlap.
Another 192 scenes compare 12288 exact background/fog pixels before and after
GC/snapshot restoration. Background expectations use independent rational
pixel-center mapping; fog uses camera rays intersecting the original plane.
Binary fixtures cover Background/Fog references, both fog modes and malformed
mode, crop and density values.
Six more scenes compare 1536 hierarchy/alpha/layer/blending pixels; 128 original
plane/ray scenes compare 8192 textured pixels, including all format/blend pairs,
two texture units, wrapping/filtering, flat/smooth colors, projective coordinates
and fog. These pixel arrays are retained and checked after GC/snapshot restore.
Another 128 lighting scenes compare 8192 pixels against a 70-digit Decimal
lighting oracle and exact Fraction ray intersections with original triangles.
They cover 8/16-bit biased normals, nonuniform/sheared/reflected models, camera
transforms, all four light modes, tracking, diffuse alpha, negative intensities,
scope/enables, attenuation, spotlights, specular powers, front/back flat/smooth
colors and texture/fog composition. A restored World/material/light graph is
rendered anew and checked against 64 expected pixels.
128 further projected-rectangle sprite scenes compare 32768 pixels against an
independent 75-digit Decimal oracle, including signed crops, both scaling modes,
all five source formats, viewport clipping, generic/perspective projection,
projective immediate model transforms, ignored appearance attributes, fog,
alpha/blending and scope/enables. Separate tests check mutable images, MIDP
origin/clip, border samples not writing depth, binary Sprite3D objects, malformed
crop/reference payloads and graph state. A restored Sprite3D is redrawn and
compared against 256 expected pixels.

Asphalt3StreetRules3D now reaches a rendered race in a 30-second input probe.
BMW Racing's exact SHA-256 has a verified 320x240 launch profile: its sizeChanged
handler suspends the game at any other width. JAR/JAD attributes and manual
selection keep their priority. A real adapter run with auto size saves/loads and
reaches a 320x240 3D start scene. This profile does not migrate old wrongly-sized
GameCanvas buffers; Biplanes-specific migration is restricted to its own hash.
These are bounded scenarios, not full playthroughs. Beach Ping Pong now loads
KeyframeSequence (type 19) and controllers/tracks, and SkinnedMesh, and reaches the bounded match described below.
The reviewed Bimmer resources use the exact compatibility profiles described
below. Scaled sprites now participate in camera-based picking, as described below.
Object3D.find follows reference/child insertion order; duplicate IDs remain legal
and any matching object is allowed by the API. This deterministic choice avoids
returning the car's VertexBuffer instead of the track Appearance for NFS ID 51.

Object3D duplication now strips user subclasses to their nearest implemented
M3G API base class and copies M3G attributes, excluding application instance
fields. This follows the API contract, rather than cloning the application class.

This is a partial M3G implementation. Mipmapping quality hints and Loader download
protocols remain to be implemented. Missing methods/classes fail explicitly. The host does not advertise
`microedition.m3g.version`. The supplied Need for Speed: Most Wanted edition
reaches the textured car/road scene described above.

`codex-work/jvm-j2me/m3g/prepare.py` creates a guest fixture without bundled SDK
classes and an exact-rational oracle for 128 matrix products/vectors and 64
inverses. `build-checks.ps1` checks geometry dispatch, errors, copies, references,
GC and snapshot restoration on Windows; these are bounded implementation tests,
not M3G certification or evidence of 3D game playability.
The contracts follow Nokia's preserved M3G 1.1 documentation:
[Transform](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Transform.html),
[Transformable](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Transformable.html),
[Node](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Node.html),
[Group](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Group.html),
[Camera](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Camera.html),
[World](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/World.html),
[Light](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Light.html),
[Object3D](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Object3D.html),
[Mesh](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Mesh.html),
[Appearance](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Appearance.html),
[Material](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Material.html),
[Image2D](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Image2D.html),
[Texture2D](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Texture2D.html),
[CompositingMode](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/CompositingMode.html),
[PolygonMode](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/PolygonMode.html),
[Loader](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Loader.html),
[Graphics3D](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Graphics3D.html),
[VertexArray](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/VertexArray.html),
[VertexBuffer](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/VertexBuffer.html),
[TriangleStripArray](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/TriangleStripArray.html).


The native KeyframeSequence module adds timestamp/vector storage, all five
interpolation modes, looping/constant sampling, wrapped valid ranges,
coincident keys, nonuniform tangent timing and the three binary encodings.
Internal arrays are copied independently by duplicate and restored through the
ordinary guest heap. Deferred sequence validity checks also run during loading.
SLERP keeps quaternion signs; stable perpendicular-direction evaluation avoids
roundoff amplification close to opposed keys. Zero or exactly opposed
quaternions have undefined interpolation in the API. Sampling is an internal
foundation used by Object3D.animate, controllers, track binding and MorphingMesh weights.

`prepare-sequences.py` follows `prepare.py`, and `build-sequences.ps1` checks
86 independent sequence cases, 4240 sample vectors / 11428 components per pass,
before and after GC/snapshot restoration. Rational scalar polynomial and complex
SU(2) matrix oracles cover every interpolation mode. 2867 guest API/Loader
assertions include all 22 original keyframe payloads from Beach Ping Pong;
2877 assertions include restored state checks. A bounded game probe still
now loads all six models including SkinnedMesh and reaches a bounded match.
Menu frames and PCM from this probe do not establish gameplay. These tests are
not M3G certification.


Native AnimationController/AnimationTrack and Object3D.animate now connect the
keyframe evaluator to implemented scene/component properties. Controller speed
changes preserve position, signed world-time subtraction avoids integer wrap,
active intervals include start/exclude end (equal endpoints mean always active),
and zero weights disable contribution. Tracks validate property/vector size and
attachment compatibility, including consistent sizes per target. Bindings use
copy-on-write guest arrays, so duplicate Nodes/components share tracks but can
independently add/remove them. Native references/find include track/sequence/
controller graphs; animation visits all reachable components once, including
Backgrounds and materials behind appearances. Render enable does not suppress
animation traversal. Samples are summed with their weights without dividing by
total weight. Final values are clamped/rounded to legal target values; camera
generic projections ignore parameter animation. MorphingMesh weights use property 266.

Quaternion inputs are normalized only when set for SLERP/SQUAD; the normalized
values are retained in internal guest double arrays to avoid another normalization
on sampling. getKeyframe still returns float vectors. Old guest float arrays
remain supported. Weighted orientation samples normalize only at application;
LINEAR quaternion samples are not normalized before weighting. The ordinary
snapshot heap stores controller data, bindings and precise/legacy key arrays.

Loader types 1/2 and common animation references are implemented. Four complete
Beach Ping Pong resources 0/1/2/5 and the two SkinnedMesh models 3/4 load.
A bounded match with save/load is checked below; a full playthrough remains unverified. Varying active tracks return a
conservative zero validity, while inactive/frozen graphs can return an interval
before another update is needed; STEP validity is not yet optimized.

The additional prepare-animation.py/build-animation.ps1 fixture checks 6355
assertions, including 128 rational blend/timing scenes (1536 time samples),
property compatibility/clamps, sharing/duplicates, malformed Loader records and
real models. After GC/snapshot it reaches 6368 assertions and compares 256 pixels
rendered at a new animation time to an independent expected rectangle. This
preserves explicit distinction between tested data/API behavior and full mobile
game/device compatibility. The same four Windows configurations retain all
keyframe/graphics/model regression checks.

Animation contracts follow Nokia's preserved [AnimationController](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/AnimationController.html),
[AnimationTrack](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/AnimationTrack.html) and
[Object3D](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Object3D.html) documentation.


Native SkinnedMesh adds an immutable skeleton child, weighted bone ranges and
captured mesh-to-bone rest transforms. Overlapping calls for the same bone are
aggregated before selecting the four strongest per-vertex bones; ties use stable
bone insertion order. Selected integer weights are normalized per vertex, and
vertices with no selected bones retain their ordinary Mesh transformation.
At-rest matrices are captured by addTransform; repeated calls keep the first
valid capture (permitted by the API), but every call still verifies invertibility.
The render palette is computed from current bone-to-mesh paths times those rest
matrices. Normals follow the inverse transpose of the blended matrix, composed
with ordinary model-view lighting; this adopts a permitted matrix-palette path
from [Khronos OES_matrix_palette](https://registry.khronos.org/OpenGL/extensions/OES/OES_matrix_palette.txt).
Singular normal maps are undefined and use an identity fallback. Picking includes
skinned geometry and skeleton attachments; this is not a claim of complete M3G support.

The skeleton and its renderable descendants traverse as part of the scene;
mesh scope does not suppress independently scoped skeleton attachments. Render
disable still suppresses descendants. Range checks are deferred until the skin
is rendered; getBoneVertices can query valid 16-bit vertex ranges even before a
VertexBuffer contains those vertices. Object3D references include bones and
skeletons, and Node duplication remaps copied skeleton/bone references. Internal
range/bind arrays extend by copy, while current node poses remain guest fields;
all state therefore uses existing GC/snapshot machinery without a format change.

Graphics3D.getProperties now returns a fresh String-keyed guest Hashtable with
all 14 standard capability entries. It reports four transforms per vertex,
two texture units, 1024 viewport/texture/crop limits and 64 concurrent matching
lights. Immediate/world light arrays can contain more lights; shading selects
the first 64 enabled matching entries deterministically. True color, perspective
correction and local camera lighting are supported; antialiasing, dithering and
mipmapping are not advertised. The M3G package version remains unadvertised while
other required APIs remain incomplete.

prepare-skin.py/build-skin.ps1 checks 4072 guest assertions / 4075 after restore,
128 exact rational inverse-bind/pose/blend cases (8192 matrix components per pass),
1616 expected normalized weights, deferred/atomic errors, duplicate remapping,
normal lighting and 256 independent triangle pixels before/after restore.
Both real Beach Ping Pong skins load and recover the rest pose of 366 vertices.
Combined fixtures load all six original models. A 20-second input probe reaches
a rendered 3D match; an isolated 45-second normal adapter run saves/loads and
pauses/resumes, with post-load character/ball/score progression visually checked.
This is bounded evidence, not a full playthrough or mobile hardware validation.
The contracts follow Nokia's preserved [SkinnedMesh](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/SkinnedMesh.html)
and [Graphics3D](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/Graphics3D.html) documentation.

### M3G morphing meshes

Native MorphingMesh implements both constructors, target access and copied weight
arrays. Targets remain shared components; duplicate Nodes can change weights
independently through copy-on-write guest arrays. Object references, GC and
snapshots retain targets, weights and animation tracks without native side tables.
Loader type 15 reads target buffers and initial weights; all 22 scene object types
now have native readers. This does not imply full M3G API support.

Rendering validates target layouts when a visible submesh is actually drawn.
Positions, normals, colors and both texture units use B + sum(w * (T - B));
weights are not normalized or constrained to [0,1]. Base-only arrays and base
scale/bias are retained. Default vertex color also morphs. Intermediate components
retain fractional precision; normals enter the ordinary lighting normalization
after interpolation. MORPH_WEIGHTS tracks zero missing vector components and
ignore surplus components.

The morph fixture checks 128 exact-rational cases, 3712 attribute components,
128 default colors and 256 animated pixels before and after GC/snapshot.
Independent pixel cases cover RGBA/node alpha, normal interpolation, two projective
texture units, default colors and base-only arrays. The original Snake III model loads with its relative external PNG. Together with
Golden Warrior's reviewed fountain it passes 3654 endpoint component checks.
The fountain uses the exact-resource compatibility profile described below;
unknown files retain strict file-format validation.
Neither the synthetic tests nor a startup probe establish handset rendering parity
or full game playability. Picking and alignment have their own tests below.

References: Nokia's preserved [MorphingMesh API](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/MorphingMesh.html)
and [M3G file format](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/file-format.html).

### Long J2ME audio resources

Finite MIDI/WAV resources whose expanded PCM would exceed the short-clip budget
use on-demand decoding. The player retains encoded data and a window of at most
4097 source frames, including the sample carried across an interpolation boundary.
Duration, seeking, loop counts, volume/mute and the ordinary resampling/mixing path
continue to operate on the complete resource. Small clips retain their original
PCM path. This removes the former roughly 95-second stereo/44.1-kHz clip limit
without increasing the whole-clip PCM allocation budget.

The original Snake III music resource is 108 seconds according to JDK MIDI timing;
the native decoder adds its existing two-second release tail. Its 110-second clip
now realizes and produces sound without the previous decoded-clip exception and
consequent game-side String-to-Player casts.

Snapshots containing a streaming player use J2ME.Media-2, with 64-bit frame counts,
stream flags and cache origins. Short-clip-only states retain J2ME.Media-1; old
media states remain readable. Streaming snapshots retain a bounded PCM window;
decoder state beyond that window is reconstructed from encoded data on demand.
Forward/backward seeking and cache reconstruction check the VM stop request every
4096 source frames. Reconstruction cost grows with the requested position;
there is no serialized synthesizer state or constant-time MIDI seeking yet.
Malformed frame/cache ranges are rejected before audio rendering.

Tests under codex-work/jvm-j2me/stream-audio compare long MIDI PCM with a separate
instance of the existing decoder and long WAV PCM with independent integer
resampling expectations. They cover cache boundaries, snapshot continuation,
seeking past the old limit, stop/deallocate/resume, looping and final EOF.
The MIDI comparison checks integration with the existing synthesizer; it is not
an independent sound synthesis oracle or physical handset audio comparison.

### Reviewed M3G resource profiles

Golden Warrior and Bimmer contain M3G exports with a nonzero third texture bias
on two-component arrays. The file format requires zero, although the component
is unused by the vertex API. Exact SHA-256 profiles for 24 reviewed models allow
normalizing only this unused component. Profiles identify the complete M3G asset
within its declared byte range, including when embedded at a byte-array offset.
They do not depend on resource names, title strings, JAR packaging or scene IDs.

Three exact Bimmer PNG resources contain complete images followed by stale bytes
from a replaced image. M3G Loader recognizes their full resource hashes and decodes
the validated PNG prefix. These exceptions do not alter the shared PNG decoder or
relax other texture, vertex, checksum, scalar or object validations. A changed
model UID or an altered trailing PNG byte loses the profile and remains rejected.
Original library JARs are not rewritten.

A test-only container holds original resources and independently normalized copies
from four installed JAR editions. All 50 model pairs produce identical complete
heap graphs: object classes, attributes, primitive arrays, user parameters, shared
references and cycles. Checks include GC and selected complete-state restores;
this validates the limited normalization, not hardware rendering parity.
Golden Warrior now reaches a textured dungeon scene. A Bimmer TimerTask reads the
game's cleared Bimmer.c field during a screen switch and terminates. The original
diagnostic probe stopped on any child-thread error; the ordinary runtime lets
other threads continue. The opt-in test option `--continue-child-errors` records
these faults while following the production behavior. Both Bimmer editions reach
a rendered race in a direct runtime probe after RayIntersection is available.
The game constructs this class but does not call Group.pick. Earlier adapter
runs ended on the sound menu after emulator pause invoked startApp again. The
separate suspension path described below preserves both editions' races through
pause and repeated save/load. These are bounded runs, not full playthroughs.
Timer behavior has not been changed to hide game errors.

### M3G picking and node alignment

Group supports both pick overloads and native RayIntersection results. Mesh,
MorphingMesh and SkinnedMesh triangles use the actual transformed geometry,
submesh appearances, scopes, inherited picking flags and polygon culling.
The ray parameter is not restricted to a unit segment. Hit normals stay in local
node coordinates; texture coordinates include both texture units and projective
texture transforms. Scaled Sprite3D picking uses the same projected extent helper
as rendering and checks image alpha before applying node alpha. Unscaled sprites
and the three-dimensional ray overload do not pick sprites. A missed pick leaves
the supplied result unchanged. RayIntersection is not an Object3D/Loader object.

Node exposes setAlignment, align and the two alignment queries. Alignment changes
only R in T*R*S*M and ignores the old R/S/M during target computation. Origin
targets transform as points and axis targets as vectors. Z has priority; Y then
minimizes its angle about the new Z axis. A single enabled axis uses the shortest
rotation. Antiparallel single-axis targets use a deterministic half-turn about X;
undefined zero-length origin targets and parallel secondary constraints use a
deterministic identity rotation for that step. Alignment is explicit, including
all descendants and skeletons, regardless of render/pick enables or scope.
Graph/path errors and required singular inverses raise the specified Java errors.

Alignment references are retained through ordinary guest fields and snapshots,
but are excluded from Object3D.getReferences/find/animate traversal. Node branch
duplication remaps references within the copied branch and preserves outside
references. Loader reads the alignment flag, targets and typed node references,
with malformed fields reported as IOException; it does not apply alignment.

The picking fixture uses 128 exact-Fraction intersection scenes with independent
texture and normal expectations, plus API, sprite, morph, skin and GC/state tests.
The alignment fixture uses 128 independent Fraction/70-digit Decimal cases:
exact parent/reference paths, projection onto the perpendicular plane for two
axes, and two Householder reflections for single-axis expectations. Eight binary
fixtures exercise Loader alignment fields and errors. Checks also cover branch
duplication, ignored old transforms, explicit updates, graph errors, actual pick
results after alignment and continued alignment after GC/state restoration.
These checks are not handset parity, certification or full game playthroughs.

### Reviewed orphan World camera resources

Six exact FastAndFurious resources declare an active Camera but omit it from the
World hierarchy. The game's render loop catches the resulting IllegalStateException
each frame, leaving the race HUD over a black surface. For these six SHA-256 model
identities, Loader appends only the unparented active camera to its World. An unused
second camera in the intro stays unchanged. Resource identity covers the declared
M3G byte range; names, object IDs and JAR title strings do not select the repair.
The JARs are not rewritten, and neither setActiveCamera nor render(World) silently
attaches arbitrary cameras. Unknown resources retain ordinary validation, including
the [World camera contract](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/javax/microedition/m3g/World.html).

Independent test files add the same missing edge in the serialized child list and
rebuild container lengths/compression/checksums. All other decoded object bytes
are compared unchanged. Native-loaded original/profiled graphs exactly match
these independently serialized files, including every attribute, array, shared
reference and parent link before/after GC and state restoration. Mutating a model
UID removes the profile, leaves the camera orphaned and preserves the rendering
error. The six models pass 570931 graph/API checks in each Windows configuration.

The original game reaches a visible race in a 70-second ordinary adapter test with
steering/acceleration, save/load and pause/resume; the post-load car/road scene was
visually checked. This does not prove full race completion or handset parity.
Older untagged snapshots that already contain a broken orphan-camera graph are
not automatically migrated; newly loaded repaired graphs persist normally.
Airburster's separate startup/timing and text issues are described below.

### Automatic Canvas display cadence

Automatic Canvas repaint delivery now coalesces requests at a 16-ms display
interval, measured from the beginning of a paint so that a slow frame does not
incur another idle interval afterward. Newly visible canvases wait for their first
interval. This is an emulator display scheduling choice; MIDP does not require a
particular refresh rate. Explicit serviceRepaints and callSerially's pending-paint
flush retain their synchronous behavior. GameCanvas.flushGraphics is unaffected.
Java clock values, arithmetic and guest exception propagation are unchanged.

The next automatic paint deadline is an optional ordinary guest field. GC/state
restoration retains it along with the restored monotonic clock; an older state
without that field initializes a fresh interval. No snapshot format change is
needed. The cadence fixture checks automatic request coalescing, explicit painting,
unchanged catchable paint exceptions, GC/state restore and legacy missing fields
on Win32/Win64 Debug/Release. Pixel checks now wait for an asynchronous frame using
wall-clock deadlines rather than assuming a fixed instruction count is enough.

Airburster's initial paint had occurred within the constructor's clock millisecond,
causing its uninitialized duration to become a zero divisor. Deferring that first
automatic paint removes this specific failure. The subsequent language-resource
failure is addressed by the reviewed default-encoding profile described below.
A 16-title priority matrix retains initial frames in eight-second runs; this is
startup coverage, not full game validation. Rodent Panic reaches a 3D scene in a
separate 25-second input probe without child-thread errors.

### Legacy default encoding and decimal floating-point parsing

Airburster reads its six language names with String(byte[],offset,length), without
an explicit encoding. The resources contain Latin-1 bytes for French, Spanish and
Portuguese. UTF-8 replacement characters then exceed its bitmap font table. The
J2ME host now selects ISO-8859-1 when both consuming classfiles and all six reviewed
language resources match their SHA-256 identities. A changed or missing resource
leaves the ordinary UTF-8 default. This is a device compatibility profile, not
per-string encoding detection or a change to UTF-8 decoding rules. It uses the
existing reusable TJavaHost.DefaultEncoding hook, so String/getBytes, readers,
writers, PrintStream, ByteArrayOutputStream and microedition.encoding agree.
The choice is recomputed from the same suite on state restore; existing guest
decoder/writer state uses the ordinary snapshot graph. No format change is needed.
Old states already containing replacement characters or a failed game thread are
not repaired by this launch-time profile.

Java.Floating implements Float.parseFloat and Double.parseDouble for CLDC 1.1
decimal strings. It validates ASCII grammar and Java trim semantics, decimal point,
exponent and f/F/d/D suffixes, null and invalid inputs, signed zero, subnormals,
overflow, underflow, NaN and signed Infinity. Integer arithmetic compares the
decimal significand with exact dyadic rounding boundaries and rounds ties to even.
There is no intermediate host floating-point conversion, locale dependency,
double rounding or reliance on the caller's rounding mode. Java 5 hexadecimal
floating-point syntax is outside this CLDC 1.1 decimal parser's contract. These two
methods do not imply completion of the Float/Double wrapper API.

The focused fixtures cover 18 resource/profile variants and Reader/Writer
continuation before/after GC and state restore. Floating-point vectors use an
independent Fraction quotient/remainder oracle, separately checked with JDK 17;
339 valid strings include exact midpoint neighbours and the normal/subnormal and
finite/infinite boundaries, and 26 invalid strings exercise lexical rejection.
All four Win32/Win64 Debug/Release configurations pass. The original Airburster
JAR reaches a visible 3D race in a 60-second input probe without child errors;
this is bounded scene coverage, not a full playthrough or handset comparison.
The ordinary adapter also completes a 100-second race/save/load run. At this
milestone, host pause invoked the MIDlet lifecycle; a separate new-core restore
used Java * to close the resulting game-owned pause menu and saved/restored again.
The suspension change described below now keeps that race running directly after
emulator resume. Initial sparse input only reached an opponent-selection menu;
that earlier diagnostic is not counted as gameplay evidence.

Focused artifacts: codex-work/jvm-j2me/airburster-encoding/.
References: [Sun Wireless Toolkit default encoding](https://docs.oracle.com/javame/dev-tools/wtk-cldc-2.5.2-01/UserGuide-html/internationalization.html),
[CLDC 1.1 Float](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Float.html),
[CLDC 1.1 Double](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Double.html).

### Emulator suspension and MIDlet lifecycle

IEmulationCore.Pause/Resume now use TJ2MERuntime.SetExecutionPaused. This freezes
the interpreter, virtual wall/monotonic clocks and PCM position, releases held
guest keys, cancels vibration and ignores new input while suspended. Resume
continues the same guest frames and deadlines. The generic emulator pause does
not invoke MIDlet.pauseApp/startApp. Explicit TJ2MERuntime.Pause/Resume still
model the MIDP application-manager lifecycle, including a MIDlet's own paused
state and resumeRequest. Resuming the emulator does not implicitly activate a
lifecycle-paused MIDlet. Destroy and stop requests can terminate a suspended VM.

Emulator suspension is outside the serialized guest state. SaveState records the
frozen virtual clocks; the adapter applies its current pause choice after load.
No snapshot format change is needed. Legacy states that contain a host-requested
MIDlet pause retain the previous lifecycle-resume path; this may call startApp
for those older states. New paused snapshots do not create that lifecycle request.

Bimmer.startApp unconditionally constructs the initial menu and schedules its
timer. The old emulator pause therefore restarted the game after resume, and
final-frame-only diagnostics misidentified that menu as an initial input failure.
A lifecycle-resetting fixture reproduces starts=2 before this change. The new
adapter and runtime fixtures pass on Win32/Win64 Debug/Release: no extra startApp
or pauseApp, frozen guest execution/clocks/input, exact nonzero PCM continuation,
active/paused snapshots, new-core restore, preserved explicit lifecycle callbacks
and stop/destroy from suspension.

Both original Bimmer editions complete 80-second adapter races with acceleration,
steering, emulator pause and two save/load cycles, with race scenes viewed after
the final restore. Original Asphalt Urban GT 2 and Airburster each complete a
100-second race/save/load/pause/resume check and retain their game scenes. This is
bounded gameplay evidence; known Bimmer TimerTask faults during screen changes
are not suppressed, and full playthroughs/device comparisons remain outstanding.

Focused artifacts: codex-work/jvm-j2me/bimmer-adapter-input/.
Lifecycle reference: [MIDP MIDlet state callbacks](https://docs.oracle.com/javame/config/cldc/ref-impl/midp2.0/jsr118/javax/microedition/midlet/MIDlet.html).

### Float and Double numeric objects

Java.Floating now supplies final CLDC Float/Double classes with typed private
value fields, the five primitive constants, Float(float/double) and Double(double)
constructors, String valueOf, numeric getters, static/instance isNaN/isInfinite,
canonical-NaN hashCode and value equality that distinguishes the two signed zeros.
Byte/short getters first use JVM int narrowing; int/long getters share the same
NaN-to-zero, saturation and truncation helpers used by the bytecode interpreter.
The existing exact decimal parsers and bit conversion methods remain available.
Ordinary guest fields retain wrapper values through GC and complete state restore.

Decimal Float/Double toString is implemented by the subsequent floating-text stage
described below, using native integer arithmetic rather than OS/RTL formatting.
A constant-pool scan of 1877 top-level library JARs finds 12 distinct floating
method signatures; all 12 now resolve to native bindings, including
Float.toString(float). Static references are potential API demand,
not proof those paths execute or that the games are fully playable. Five files
with a .jar extension were not ZIP archives and were left unchanged.

JDK-generated vectors cover 282 float and 282 double bit patterns, including
signed zeros, infinities, signaling/quiet NaNs, subnormal boundaries, integer
saturation limits and deterministic random values. There are 8195 guest checks
per configuration, plus native metadata/constants/signature checks, Hashtable
key equality and GC/state continuation. The 30-second original-JAR input probes
retain a Pool Dreams bet menu, Snake III Game Over, Tankzors startup/settings and
an NFS Carbon loading screen. These probes do not prove gameplay improvements;
Carbon still reports rejected unused 2D texture bias Z in its M3G resources.

The new primitive fields are an explicit old-state schema upgrade. The reusable
VM offers an opt-in host hook for a saved class with exactly zero fields; its
default rejects the mismatch. TJavaHost permits this only for the reviewed current
six-field Float/Double schemas, including exact names, types, flags and default
bits. Other counts, descriptors and classes remain strict. The hook retains new
primitive defaults while reading the old empty layout, without changing the state
format or adding Java-library knowledge to the VM. Tests cover Float-only,
Double-only and both empty legacy schemas, successful guest/GC continuation, and
rejection of partial, foreign, changed-descriptor and changed-default schemas.
This schema migration does not change the legacy MIDlet-pause behavior described
above; past pauseApp side effects cannot be universally undone from that format.

Focused artifacts: codex-work/jvm-j2me/floating-api/.

### Native Java floating-point text

Java.Floating.Text supplies Float/Double static and instance toString, primitive
String.valueOf(float/double), StringBuffer/StringBuilder append/insert and the
PrintStream floating overloads with one shared converter. It handles signed zero,
NaN/Infinity, decimal/exponent thresholds, mandatory fractional digits, uppercase
E and exponent signs without host locale or floating-point conversion routines.
The Float/Double public CLDC 1.1 member set is now present; this does not imply
completion of the wider Java/JSR library or complete game compatibility.

The converter derives a decimal scale from an integer fixed-point log tangent,
then extracts digits using nonnegative integer numerator/denominator/margin
arithmetic. An internal base-2^32 record handles wider intermediates. Integral
values and bounded margin decisions preserve classic Java spelling, including
cases where another shortest-roundtrip convention would choose different digits.
All arithmetic, including scale selection, is integer-only; there are no global
mutable caches, host code-page choices or dependencies on caller FPU controls.

Independent JDK 17 strings cover 14317 float and 29248 double bit patterns: every
binade's neighbours, subnormal and special values, powers-of-ten neighbours,
deterministic random bits, and adversarial scale-selector boundaries. Exact
Fraction intervals independently verify 43492 finite strings and format thresholds.
Each Win32/Win64 Debug/Release native run performs 45503 comparisons, including
alternate host rounding modes, unmasked exceptions and comma locale. The guest
fixture checks 5115 assertions across all public string paths, native-parser
roundtrips, boxed objects and continued buffers after GC/state restore. The numeric
wrapper regression retains 8195 guest checks and now verifies all 12 library-used
signatures. Common J2ME/snapshot and real previous-executable state import pass.

Thirty-second original-JAR input probes retain an Airburster race, an Epos 3D
character/terrain scene and the NFS Most Wanted sound-selection prompt. Those
paths do not prove execution of Float.toString or full playability; a static
constant-pool reference is not execution evidence. Remaining rendering/resource
issues, other APIs/protocols and full game/device validation are still outstanding.

Focused artifacts: codex-work/jvm-j2me/floating-text/.
Formatting contracts: [CLDC 1.1 Float](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Float.html),
[CLDC 1.1 Double](https://docs.oracle.com/javame/config/cldc/ref-impl/cldc1.1/jsr139/java/lang/Double.html).


## NFS Carbon reviewed resource compatibility

The original NeedForSpeedCarbon.jar (SHA256
2b43fb9d5f9832e11ea597f329d451312ca019a6296299463679bb04403f540d,
JAMDAT build 1.1.70.efigs.sek750i) contains ten M3G resources with 59 nonzero
unused third texture-bias components on two-component texture-coordinate arrays.
The binary-format rule requires these fields to be zero. The existing exact
resource compatibility registry now recognizes the ten reviewed SHA256 values;
only those unused components are normalized. The JAR is not rewritten and other
format checks and the public VertexBuffer API remain unchanged.

An independent container/object decoder constructs reference copies that alter
only those fields and the resulting header size/compression/checksums. Native
Win32/Win64 Debug/Release tests perform 3490496 full graph comparisons per
configuration (3141 compared heap objects), including GC and state restoration
for all ten models. All ten models with changed user IDs and original invalid
bias values still fail strict validation. Existing Golden Warrior/Bimmer graph
and invalid-resource checks remain green.

Before/after 45-second original-JAR probes change from a black loading bar with
M3G IOExceptions and dependent ClassCastException to a rendered garage and car.
The trace still includes caught first-launch RMS-not-found/cleanup exceptions;
they are not suppressed. The probe alone is not a complete gameplay test.

This exact JAR also has fixed 176x220 menu clipping/layout in aa/p bytecode, even
though its race viewport can grow. Its reviewed launch profile now selects
176x220 in auto mode. JAR/JAD dimensions and manual choices retain their priority;
changed identities do not receive the profile. Old states retain their stored
viewport; this change does not rewrite or resize them.

An additional 100-second isolated adapter run at auto-selected 176x220 reaches
the 3D race, saves/loads the race, pauses/resumes and continues steering. Frames
were visually checked after load/resume. This is bounded testing, not a full
playthrough or physical handset validation. Additional Java/JSR APIs, protocols,
rendering/audio fidelity and broader game/device validation remain outstanding.

Focused artifacts: codex-work/jvm-j2me/nfs-carbon/.
File-format reference: [JSR-184 VertexBuffer](https://nikita36078.github.io/J2ME_Docs/docs/jsr184/file-format.html).


## Popular-library scenes and Diamond Rush orientation

Eight original popular-library JARs were probed for 30 seconds with scripted
softkey/fire/down input, retaining frames and exception traces. Active frames
proved insufficient: Diamond Rush rendered only an orientation warning. Worms
reached a quit dialog and destruction; this is not a gameplay pass or an emulator
crash. Other reviewed frames include a Doom RPG menu, Sims interior, Angry Birds
slingshot, Doodle Jump level and Ancient Empires tutorial/map. They are bounded
scene observations, not full compatibility claims. Angry Birds probes unsupported
key names and requests two images absent from its JAR; its bounded trace also
omitted exceptions, so absence of further caught faults remains unproven.

Diamondrush.jar SHA256
1a27a721a4440e8bdf63aa456732d71cb4e0cbd00054899dd233b0f69fd96b00
(version 1.1.6) rejects width < height before its actual paint path, despite
contradictory wording in the warning. Its real clip and layout are fixed at
320x240. The reviewed exact-JAR automatic profile now uses that size. Portrait
and landscape probes show the warning versus an actual level with PCM output.
JAD and manual choices retain priority; changed JAR identities do not receive
this profile.

The same exact port also supports restoring states created with the old
240x320 fallback: in automatic mode, the existing ordinary-Canvas resize updates
the saved viewport to the selected profile/JAD size before state commit. Manual
mode preserves the saved viewport. No guest fields, game assets, exception rules
or generic Canvas behavior are rewritten. All nine Canvas dimension queries are
in i.paint's orientation-warning branch; actual game image/layout sizes are
fixed. Other titles retain their existing snapshot viewport policy.

Four Windows configurations verify portrait-state restore, repeated restore,
manual mode and JAD priority. A 90-second fresh adapter run reaches the level's
tutorial and preserves it through save/load and emulator pause. A 50-second
restored continuation skips the tutorial, moves the hero and repeats save/load;
that quiet restored scene opens no audio device, so it provides no proof about
sound after restore. An additional 80-second adapter run starts from a portrait
viewport fixture and migrates it in automatic mode; scripted input reaches Help.
Explicit 7/12-second restored follow-ups return to New Game and the level, then
20 seconds verify movement, another state roundtrip and emulator pause/resume.
User save files are not modified by these tests.

SplinterCell.jar's existing code-based detection selects 96x65. Rendering that
size removes the repeated/cropped menu regions seen in the forced 240x320 probe;
only its menu was verified, so no new profile or full-playability claim is added.
Additional APIs/protocols, rendering/audio fidelity and full game/device coverage
remain. Focused evidence: codex-work/jvm-j2me/library-scenes/.
