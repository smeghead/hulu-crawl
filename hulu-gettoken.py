#!/usr/bin/env python
from ghost import Ghost
from pprint import pprint

ghost = Ghost()
page, extra_resources = ghost.open('http://www.hulu.jp/movies')

assert page.http_status==200

result, resources = ghost.evaluate('API_DONUT')
print(result)
