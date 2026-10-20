module bleu::network::service_test;
import std::time, bleu::error, bleu::network, bleu::operation;

// D1: a command the backend never runs completes its operation, so no waiter hangs.
fn void an_abandoned_connect_fails_disconnected() @test
{
	ConnectOp* op = operation::begin{Connected}(mem);
	op.retain();
	Command command = { .kind = CONNECT, .connect = op };
	network::abandon_command(null, &command);
	assert(@catch(op.wait(time::ms(100))) == error::DISCONNECTED, "the waiter learns the service stopped");
	op.release();
}

// D1, D14: an abandoned settle fails the same way, and its secret is gone.
fn void an_abandoned_settle_fails_and_wipes_its_secret() @test
{
	SettleOp* op = operation::begin{Settled}(mem);
	op.retain();
	Command command = { .kind = SUPPLY_CREDENTIALS, .settle = op, .request = 7 };
	command.secret.bytes[0]                  = 'x';
	command.secret.bytes[network::SECRET_MAX - 1]     = 'y';
	command.secret.len                       = 2;
	network::abandon_command(null, &command);
	assert(@catch(op.wait(time::ms(100))) == error::DISCONNECTED);
	assert(command.secret.len == 0, "the length is cleared");
	assert(command.secret.bytes[0] == 0 && command.secret.bytes[network::SECRET_MAX - 1] == 0, "and every byte is zero");
	op.release();
}
