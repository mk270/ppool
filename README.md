ppool
=====

ppool is a lightweight worker pool for Erlang, originally published as
[didactic code](https://learnyousomeerlang.com/building-applications-with-otp#a-pool-of-processes)
in [Learn You Some Erlang](https://learnyousomeerlang.com/) by
Frédéric Trottier-Hébert.

Copyright (c) 2009 Frédéric Trottier-Hébert; available under the terms
of the MIT Licence.

Usage
=====

    1> ppool:start_pool(nagger, 2, {ppool_nagger, start_link, []}).
    {ok,<0.35.0>}
    2> ppool:run(nagger, ["finish the chapter!", 10000, 10, self()]).
    {ok,<0.39.0>}

