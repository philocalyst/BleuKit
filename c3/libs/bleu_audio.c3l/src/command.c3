<*
 One request queued for the worker. A command owns nothing: the service copies
 every string and slice into the operation's arena, and the worker holds a
 reference on that operation until it finishes the command.
*>
module bleu::audio;
import bleu::unit, bleu::operation;

<* Completion of a request: `true` when the server applied it. Waiting on it does not mean the world changed; that arrives in the state. *>
alias Pending = Operation{bool};

<* A queued request. `flow` is the direction of the target (a stream's flow for stream commands). *>
struct Command
{
	CommandKind kind;
	Flow flow;
	String target;       // device, stream or card id
	String choice;       // destination device id, port name or profile name
	Gain[] gains;        // volumes for SET_DEVICE_VOLUME and SET_STREAM_VOLUME
	bool flag;           // the mute value for SET_DEVICE_MUTE and SET_STREAM_MUTE
	Pending* done;       // completed exactly once by the worker
}
