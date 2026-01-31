deploy:
	rsync -avz --exclude '_build' --exclude 'deps' --exclude '.git' . pi@10.0.0.8:~/bonbontest/
