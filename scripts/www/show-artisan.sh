echo "
	tao project laravel 12:
        cat /var/www/ham-sh-mysql/huong-dan-create-laravel12.md
        echo "--------------------------------------------------"
	composer require ten-module
	composer dump-autoload
	composer update

	php artisan make:migration create_posts_table
	php artisan migrate
	php artisan db:seed

	php artisan make:seeder CreateAdminUser
	php artisan db:seed --class=CreateAdminUser

	php artisan key:generate
	php artisan optimize:clear
	php artisan list

	php artisan queue:work --queue=high,default
"
