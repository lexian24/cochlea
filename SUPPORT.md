# Support

## Something is broken

Open a [bug report](https://github.com/lexian24/cochlea/issues/new?template=bug_report.yml).

Most of this app's failures are silent, so **include the log** — it is usually
the whole report. Run it from a terminal:

```sh
./build/cochlea.app/Contents/MacOS/cochlea
```

or, if you launched it from Finder:

```sh
log stream --predicate 'subsystem == "com.cochlea.app"' --style compact
```

The timing lines alone have identified four separate defects. Four of the six
bugs found so far were invisible without them.

## Something does not work the way you expected

Check [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) first — it covers the
things that are confusing but deliberate, which is most of them.

## A question about why it works this way

[`docs/SPEC.md`](docs/SPEC.md) is a register of the failure modes the design
has to survive, and [`docs/DECISIONS.md`](docs/DECISIONS.md) records what was
measured. Between them they answer most "why not just…" questions with a
reason rather than a preference.

If they don't, open a
[discussion-style issue](https://github.com/lexian24/cochlea/issues/new?template=feature_request.yml).

## A security or privacy problem

Report privately: [SECURITY.md](SECURITY.md). If something in
[docs/PRIVACY.md](docs/PRIVACY.md) is not true, that is a security report.

## What you should expect

This is one person's project. There is no company behind it, no support
contract, and no promised response time. What there is:

- Bugs with a log attached get looked at.
- Reports from hardware other than an 8 GB M2 are especially useful, because
  that is the only machine any of this has been measured on.
- Feature requests are weighed against the failure-mode register, and "no,
  because F*n*" is a common and honest answer.
