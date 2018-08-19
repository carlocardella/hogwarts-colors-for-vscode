import sys


def exc1():
    while True:
        try:
            x = int(input("enter a number: "))
            break
        except ValueError:
            print('not a valid number')


def exc2():
    import sys

    try:
        f = open('fibonacci.py')
        s = f.readline()
        i = int(s.strip())
    except OSError as err:
        print('OSError: {0}'.format(err))
    except ValueError:
        print('count not convert to integer')
    except:
        print('unexpected error:', sys.exc_info()[0])
        raise
