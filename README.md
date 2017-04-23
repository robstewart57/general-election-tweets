# UK 2017 General Election Tweet Sentiment

This is a Twitter bot that tracks the sentiment of tweets about the
three main party leaders: Theresa May, Jeremy Corbyn and Tim Farron.

The Twitter bot account is:

https://twitter.com/party_sentiment

Implementation details:

1. The bot uses http://www.sentiment140.com to compute the sentiment
of the tweets, described in __"Twitter Sentiment Classification using
Distant Supervision"__. A. Go, R. Bhayani, L. Huang. Stanford
University. Tech
Report, 2009. [PDF](http://cs.stanford.edu/people/alecmgo/papers/TwitterDistantSupervision09.pdf).

2. It consumes relevant tweets from the Twitter streaming API using
the
[twitter-conduit](http://hackage.haskell.org/package/twitter-conduit)
Haskell library.
