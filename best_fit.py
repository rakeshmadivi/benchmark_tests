from statistics import mean
import numpy as np
import random as rnd
from pylab import *
import matplotlib.pyplot as plt
from matplotlib import style
import sys

def best_fit(xs,ys):
    m = (((mean(xs)*mean(ys))-mean(xs*ys)) /
            ((mean(xs)*mean(xs))-mean(xs*xs)))
    b = mean(ys) - m*mean(xs)

    return m,b


style.use('ggplot')

s1=sys.argv[1].rstrip().split(',')
arr=[int(elem) for elem in s1]
#ia=[1,2,34]
a=np.array(arr)
#print("ARR:",arr,"NPARR:",nparr)
print(a[1]+a[2])
b=5*rnd.randint(10,200)*a
print("ARRAYS:\n",a,b)


m,intercept=best_fit(a,b)
print("m,intercept: ",m,intercept)

n,c=polyfit(a,b,1)
plot(a,b,'yo',a,n*a+c,'--k')
show()
